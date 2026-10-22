# frozen_string_literal: true

module Sourced
  module UI
    # A layered (Sugiyama) layout of one flat directed graph, drawn top to
    # bottom. Components::Statechart lays out each region's states with it.
    #
    # 1. Ranks: breadth first from the +starts+, so most edges point down, with
    #    the +tops+ in a rank of their own above them. A node nothing reaches
    #    goes last.
    # 2. Layers: each rank is a layer of nodes, followed by a layer for labels.
    #    An edge between ranks runs through a dummy vertex in every layer
    #    between them, its label in the first label layer; an edge back up is
    #    laid out reversed. An edge within a rank runs under it, through a
    #    dummy in the label layer below, unless its ends end up side by side:
    #    then it's drawn straight across, with room kept for its label.
    # 3. Order: barycenter sweeps, down and up, keeping the order with the
    #    fewest crossings.
    # 4. Coordinates: each node pulled towards its neighbours, and each dummy
    #    towards the straight line between its edge's ends, a layer at a time,
    #    the layer packed in order without overlaps (weighted isotonic
    #    regression). Dummies pull harder, so edges bend only where they must.
    # 5. Ports: the edges at a node's top or bottom spread along it, in the
    #    order of where they go.
    #
    # Each label has a slot of its own, so labels don't overlap each other,
    # nodes, or other edges' lines.
    class LayeredLayout
      # +extra+ is room kept free to the node's right (for its self-loops).
      # A +round+ node's edges all meet it at its middle.
      Node = Data.define(:id, :w, :h, :extra, :round)
      Edge = Data.define(:id, :from, :to, :label_w, :label_h)
      # +points+ run from the edge's +from+ to its +to+. +flat+ is :straight or
      # :under for an edge within a rank, nil otherwise. +label+ is [x, y], and
      # +anchor+ its text-anchor.
      Route = Data.define(:points, :label, :anchor, :flat)
      Placed = Data.define(:x, :y)

      LABEL_INSET = 4      # where an edge runs through its label's slot, from the slot's left
      LABEL_PAD = 6        # between that line and the label
      LABEL_LAYER_PAD = 10 # above and below a label layer's labels
      MIN_LABEL_LAYER = 24 # so edges have room to bend, labelled or not
      LAYER_GAP = 4
      NODE_GAP = 18
      DUMMY_GAP = 8
      PASSING_GAP = 14     # between a node and an edge passing it
      THIN = 2
      FLAT_SPACE = 28      # around the label of an edge drawn straight across
      PORT_MARGIN = 10
      PORT_GAP = 9
      SWEEPS = 8
      PASSES = 12

      Vertex = Struct.new(:id, :kind, :w, :h, :layer, :x, :y, :node, keyword_init: true) do
        def dummy? = kind != :node
        def slot_w = w + (node ? node.extra : 0)
        # Where edges meet it, across: a label slot's line runs down its left.
        def anchor_dx = kind == :label ? LABEL_INSET : w / 2.0
        def anchor = x + anchor_dx
      end

      # Positions as close to +targets+ as they can be (weighted least
      # squares), each at least +seps[i]+ after the one before.
      def self.pack(targets, weights, seps)
        offsets = seps.each_with_object([0.0]) { |sep, acc| acc << acc.last + sep }
        blocks = [] # [sum of weight * value, sum of weights, size]
        targets.each_with_index do |target, i|
          blocks << [(target - offsets[i]) * weights[i], weights[i], 1]
          while blocks.size > 1 && blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]
            last = blocks.pop
            blocks[-1] = blocks[-1].zip(last).map(&:sum)
          end
        end
        blocks.flat_map { |sum, weight, size| [sum / weight] * size }.each_with_index.map { |z, i| z + offsets[i] }
      end

      attr_reader :width, :height, :boxes, :routes

      # @param nodes [Array<Node>]
      # @param edges [Array<Edge>] none from a node to itself
      # @param starts [Array] the nodes ranks start from (the first node, if none of them is one)
      # @param tops [Array] nodes above even those
      def initialize(nodes, edges, starts: [], tops: [])
        raise ArgumentError, 'a layout needs nodes' if nodes.empty?

        @nodes = nodes
        @edges = edges
        @edges_by_id = edges.to_h { [it.id, it] }
        build(rank(starts, tops))
        order
        straighten_flat
        assign_y # first: heights don't depend on positions across, and dummies are placed by them
        assign_x
        @boxes = nodes.to_h { |n| v = @v.fetch(n.id); [n.id, Placed.new(x: v.x, y: v.y)] }
        @routes = edges.to_h { [it.id, route(it, @chains.fetch(it.id))] }
      end

      private

      def rank(starts, tops)
        out = Hash.new { |h, k| h[k] = [] }
        @edges.each { out[it.from] << it.to }
        ids = @nodes.map(&:id)
        tops = tops.select { ids.include?(it) }
        firsts = (starts.select { ids.include?(it) } - tops).then { it.empty? ? [(ids - tops).first].compact : it }
        ranks = tops.to_h { [it, 0] }.merge(firsts.to_h { [it, tops.empty? ? 0 : 1] })
        queue = tops + firsts
        while (id = queue.shift)
          out[id].each do |to|
            next if ranks.key?(to)

            ranks[to] = ranks.fetch(id) + 1
            queue << to
          end
        end
        last = ranks.values.max + 1
        ids.each { ranks[it] ||= last }
        ranks
      end

      def build(ranks)
        @v = {}
        rows = Hash.new { |h, k| h[k] = [] }
        @nodes.each do |node|
          v = Vertex.new(id: node.id, kind: :node, w: node.w, h: node.h, layer: ranks.fetch(node.id) * 2, node:)
          @v[node.id] = v
          rows[v.layer] << v
        end

        @chains = {}   # edge id => its vertices, the upper end first
        @reversed = {} # edge id => laid out from its +to+ down to its +from+
        @flat = {}     # edge id => :under or :straight
        @edges.each do |edge|
          a = @v.fetch(edge.from)
          b = @v.fetch(edge.to)
          raise ArgumentError, "#{edge.from.inspect} loops to itself: draw it apart" if a.equal?(b)

          if a.layer == b.layer
            d = dummy(rows, edge, :under, a.layer + 1, edge.label_w + 8, edge.label_h + 8)
            @chains[edge.id] = [a, d, b]
            @flat[edge.id] = :under
          else
            upper, lower = [a, b].sort_by(&:layer)
            @reversed[edge.id] = !upper.equal?(a)
            mids = (upper.layer + 1...lower.layer).each_with_index.map do |layer, i|
              if i.zero?
                dummy(rows, edge, :label, layer, LABEL_INSET + LABEL_PAD + edge.label_w, edge.label_h)
              else
                dummy(rows, edge, :thin, layer, THIN, 0)
              end
            end
            @chains[edge.id] = [upper, *mids, lower]
          end
        end

        @layers = (0..rows.keys.max).map { rows[it] }
        # A dummy between ranks => [its edge's upper end, lower end].
        @along = {}.compare_by_identity
        @chains.each_value do |upper, *mids, lower|
          next if upper.layer == lower.layer

          mids.each { @along[it] = [upper, lower] }
        end
        @neighbours = Hash.new { |h, k| h[k] = [] }.compare_by_identity
        @chains.each_value { |chain| chain.each_cons(2) { |p, q| @neighbours[p] << q; @neighbours[q] << p } }
      end

      def dummy(rows, edge, kind, layer, w, h)
        Vertex.new(id: [edge.id, kind, layer], kind:, w:, h:, layer:).tap { rows[layer] << it }
      end

      def order
        best = @layers.map(&:dup)
        fewest = crossings(best)
        layers = @layers.map(&:dup)
        last = layers.size - 1
        SWEEPS.times do |sweep|
          down = sweep.even?
          (down ? (1..last) : (last - 1).downto(0)).each do |l|
            ref = index(layers[down ? l - 1 : l + 1])
            layers[l] = layers[l].each_with_index.sort_by do |v, i|
              at = @neighbours[v].filter_map { ref[it] }
              [at.empty? ? i : at.sum.fdiv(at.size), i]
            end.map(&:first)
          end
          count = crossings(layers)
          if count < fewest
            fewest = count
            best = layers.map(&:dup)
          end
        end
        @layers = best
      end

      def index(row) = row.each_with_index.to_h.compare_by_identity

      def crossings(layers)
        layers.each_cons(2).sum do |upper, lower|
          up = index(upper)
          down = index(lower)
          segments = upper.flat_map { |v| @neighbours[v].filter_map { down[it] }.map { [up[v], it] } }
          segments.combination(2).count { |(a1, b1), (a2, b2)| (a1 - a2) * (b1 - b2) < 0 }
        end
      end

      # An edge within a rank whose ends are side by side is drawn straight
      # across: its dummy goes, and the gap between them fits its label.
      def straighten_flat
        @flat_gap = {}.compare_by_identity # the left node of a pair => the gap to its right
        @flat.keys.each do |id|
          a, d, b = @chains.fetch(id)
          row = @layers[a.layer]
          i = row.index { it.equal?(a) }
          j = row.index { it.equal?(b) }
          next unless (i - j).abs == 1

          @layers[d.layer].reject! { it.equal?(d) }
          [a, b].each { |v| @neighbours[v].reject! { it.equal?(d) } }
          @chains[id] = [a, b]
          @flat[id] = :straight
          left = i < j ? a : b
          @flat_gap[left] = [@flat_gap[left] || 0, @edges_by_id.fetch(id).label_w + FLAT_SPACE].max
        end
      end

      def assign_x
        @layers.each { place_row(it, it.map { 0.0 }) }
        PASSES.times do |pass|
          (pass.even? ? @layers : @layers.reverse).each do |row|
            targets = row.map do |v|
              if (upper, lower = @along[v])
                # Where the straight line between the edge's ends crosses the dummy's middle.
                top = upper.y + upper.h
                t = ((v.y + @layer_h.fetch(v.layer) / 2.0 - top) / (lower.y - top)).clamp(0.0, 1.0)
                upper.anchor + (lower.anchor - upper.anchor) * t - v.anchor_dx
              elsif (near = @neighbours[v]).any?
                near.sum(&:anchor).fdiv(near.size) - v.anchor_dx
              else
                v.x
              end
            end
            place_row(row, targets)
          end
        end
        all = @layers.flatten
        left = all.map(&:x).min
        all.each { it.x -= left }
        @width = all.map { it.x + it.slot_w }.max
      end

      def place_row(row, targets)
        return if row.empty?

        seps = row.each_cons(2).map do |p, q|
          gap = if p.dummy? && q.dummy? then DUMMY_GAP
                elsif p.dummy? || q.dummy? then PASSING_GAP
                else NODE_GAP
                end
          p.slot_w + [gap, @flat_gap[p] || 0].max
        end
        weights = row.map { it.dummy? ? 4.0 : 1.0 }
        LayeredLayout.pack(targets, weights, seps).each_with_index { |x, i| row[i].x = x }
      end

      def assign_y
        @layer_h = []
        y = 0.0
        @layers.each_with_index do |row, l|
          h = row.map(&:h).max || 0
          h = [h + LABEL_LAYER_PAD * 2, MIN_LABEL_LAYER].max if l.odd?
          @layer_h << h
          row.each { |v| v.y = v.dummy? ? y : y + (h - v.h) / 2.0 }
          y += h + LAYER_GAP
        end
        @height = y - LAYER_GAP
      end

      # The x where each edge meets a node's top or bottom: spread along it,
      # in the order of where the edges go next.
      def ports
        @ports ||= begin
          sides = Hash.new { |h, k| h[k] = [] }
          @chains.each do |id, chain|
            case @flat[id]
            when :straight then next
            when :under
              # Each end on the side facing the other, so the curve is a U.
              a, _, b = chain
              sides[[a.id, :bottom]] << [[id, :a], b.anchor]
              sides[[b.id, :bottom]] << [[id, :b], a.anchor]
            else
              sides[[chain.first.id, :bottom]] << [[id, :upper], chain[1].anchor]
              sides[[chain.last.id, :top]] << [[id, :lower], chain[-2].anchor]
            end
          end
          sides.each_with_object({}) { |((id, _), list), acc| acc.merge!(spread(@v.fetch(id), list)) }
        end
      end

      def spread(v, list)
        middle = v.x + v.w / 2.0
        return list.to_h { |key, _| [key, middle] } if v.node.round

        margin = [PORT_MARGIN, v.w / 2.0].min
        lo = v.x + margin
        hi = v.x + v.w - margin
        sorted = list.sort_by(&:last)
        xs = LayeredLayout.pack(sorted.map { it.last.clamp(lo, hi) }, sorted.map { 1.0 }, [PORT_GAP] * (sorted.size - 1))
        xs = if xs.last - xs.first > hi - lo
               # More edges than the side has room for at PORT_GAP: share it out.
               step = (hi - lo) / (sorted.size - 1)
               sorted.each_index.map { lo + it * step }
             else
               shift = [xs.last - hi, 0].max - [lo - xs.first, 0].max
               xs.map { it - shift }
             end
        sorted.map(&:first).zip(xs).to_h
      end

      def route(edge, chain)
        case @flat[edge.id]
        when :straight then straight(edge)
        when :under
          # Down from one end, across through the label layer, and up into the
          # other: lowest midway between them, the label in its slot below.
          a, d, b = chain
          x1 = ports.fetch([edge.id, :a])
          x2 = ports.fetch([edge.id, :b])
          low = d.y + LABEL_LAYER_PAD
          Route.new(points: [[x1, a.y + a.h], [(x1 + x2) / 2.0, low], [x2, b.y + b.h]],
                    label: [d.anchor, low + edge.label_h + 2], anchor: 'middle', flat: :under)
        else
          upper, *mids, lower = chain
          points = [[ports.fetch([edge.id, :upper]), upper.y + upper.h]]
          label = nil
          # Through each label layer at its middle, so the edge bends across the
          # whole of each gap, beside its label; past each row of nodes upright,
          # top to bottom, so it can't swing into the nodes either side.
          mids.each do |d|
            if d.layer.even?
              points << [d.anchor, d.y] << [d.anchor, d.y + @layer_h.fetch(d.layer)]
            else
              middle = d.y + @layer_h.fetch(d.layer) / 2.0
              points << [d.anchor, middle]
              label = [d.anchor + LABEL_PAD, middle + 4] if d.kind == :label
            end
          end
          points << [ports.fetch([edge.id, :lower]), lower.y]
          points.reverse! if @reversed[edge.id]
          Route.new(points:, label:, anchor: 'start', flat: nil)
        end
      end

      # Side to side, level with the nodes' middles. Two edges between the same
      # pair, one each way, run apart: the rightward one above, its label over
      # it, the leftward one below, its label under it.
      def straight(edge)
        a = @v.fetch(edge.from)
        b = @v.fetch(edge.to)
        rightward = a.x < b.x
        both_ways = @edges.any? { it.from == edge.to && it.to == edge.from && @flat[it.id] == :straight }
        y = (a.y + a.h / 2.0 + b.y + b.h / 2.0) / 2.0
        y += rightward ? -5 : 5 if both_ways
        x1 = rightward ? a.x + a.w : a.x
        x2 = rightward ? b.x : b.x + b.w
        Route.new(points: [[x1, y], [x2, y]], label: [(x1 + x2) / 2.0, rightward ? y - 6 : y + 13],
                  anchor: 'middle', flat: :straight)
      end
    end
  end
end

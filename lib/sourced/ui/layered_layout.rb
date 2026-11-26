# frozen_string_literal: true

module Sourced
  module UI
    # A layered (Sugiyama) layout of one flat directed graph, drawn top to
    # bottom. Components::Statechart lays out each region's states with it.
    # Several ideas are Pele's (https://github.com/obsidianmd/pele,
    # src/layout/layered.ts): cycles broken depth first, long edges run
    # straight and turn only at their ends, and fixed border ports.
    #
    # 1. Ranks: breadth first from the +starts+, so most edges point down, with
    #    the +tops+ in a rank of their own above them and the +bottoms+ in one
    #    below everything. Then only the edges that close a cycle (found depth
    #    first) point up: the target of any other moves down below its source.
    #    A node nothing reaches goes last. (.ranks, which needs only the graph.)
    # 2. Layers: each rank is a layer of nodes, followed by a layer for labels.
    #    An edge between ranks runs through a dummy vertex in every layer
    #    between them, its label in the first label layer; an edge back up is
    #    laid out reversed. An edge within a rank runs under it, through a
    #    dummy in the label layer below, unless its ends end up side by side:
    #    then it's drawn straight across, with room kept for its label.
    # 3. Order: barycenter sweeps, down and up, keeping the order with the
    #    fewest crossings. Nodes with a +hint+ keep the order of their hints.
    # 4. Coordinates: each node pulled towards its neighbours, a layer at a
    #    time, the layer packed in order without overlaps (weighted isotonic
    #    regression). An edge's dummies start on the straight line between its
    #    ends, then pull towards each other, so the edge runs straight down
    #    past every rank it skips and bends only near its ends. Dummies pull
    #    harder, so edges bend only where they must.
    # 5. Ports: the edges at a node's top or bottom spread along it, in the
    #    order of where they go, around any fixed there (+from_dx+, +to_dx+).
    #
    # Each label has a slot of its own, so labels don't overlap each other,
    # nodes, or other edges' lines.
    class LayeredLayout
      # +extra+ is room kept free to the node's right (for its self-loops).
      # A +round+ node's edges all meet it at its middle. Nodes with a +hint+
      # keep the order of their hints in their rank (a compound state's border
      # ports, in the order of where their edges go outside it).
      Node = Data.define(:id, :w, :h, :extra, :round, :hint) do
        def initialize(hint: nil, **) = super
      end
      # +from_dx+ and +to_dx+, if given, fix where the edge meets its ends:
      # that far from the node's left (a compound state's border port).
      Edge = Data.define(:id, :from, :to, :label_w, :label_h, :from_dx, :to_dx) do
        def initialize(from_dx: nil, to_dx: nil, **) = super
      end
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
      LOOP_CLEARANCE = 11  # how far below the middle an edge runs past a node's +extra+ (see #straight)
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

      # Each node's rank, from just the graph: +ids+, and +edges+ as [from, to]
      # pairs. See #initialize for +starts+, +tops+ and +bottoms+.
      def self.ranks(ids, edges, starts: [], tops: [], bottoms: [])
        out = Hash.new { |h, k| h[k] = [] }
        edges.each { |from, to| out[from] << to }
        tops = tops.select { ids.include?(it) }
        bottoms = bottoms.select { ids.include?(it) } - tops
        rest = ids - tops - bottoms
        firsts = (starts.select { rest.include?(it) }).then { it.empty? ? [rest.first].compact : it }
        ranks = tops.to_h { [it, 0] }.merge(firsts.to_h { [it, tops.empty? ? 0 : 1] })
        queue = tops + firsts
        while (id = queue.shift)
          out[id].each do |to|
            next if ranks.key?(to) || bottoms.include?(to)

            ranks[to] = ranks.fetch(id) + 1
            queue << to
          end
        end
        sink(ranks, out, tops + firsts, tops)
        last = (ranks.values.max || -1) + 1
        rest.each { ranks[it] ||= last }
        below = (ranks.values.max || -1) + 1
        bottoms.each { ranks[it] = below }
        ranks
      end

      # Breadth first puts a node at its shortest way from the start, so an
      # edge into it from further along points back up although it closes no
      # cycle (+FailVerification+ into +failed+, reached sooner by
      # +FailPreparation+). Only the edges that do close one, found depth first
      # from +roots+ in definition order, point up: the target of any other
      # edge pointing up moves down below its source, and on along its edges.
      # The +fixed+ nodes stay where they are.
      def self.sink(ranks, out, roots, fixed)
        back = Set.new
        state = {}
        roots.each do |root|
          next if state[root]

          state[root] = :open
          stack = [[root, out[root].each]]
          until stack.empty?
            id, targets = stack.last
            begin
              to = targets.next
              case state[to]
              in :open then back << [id, to]
              in nil
                state[to] = :open
                stack << [to, out[to].each]
              else nil
              end
            rescue StopIteration
              state[id] = :done
              stack.pop
            end
          end
        end

        loop do
          moved = false
          ranks.keys.each do |id|
            out[id].each do |to|
              next if !ranks.key?(to) || fixed.include?(to) || back.include?([id, to]) || ranks.fetch(to) >= ranks.fetch(id)

              ranks[to] = ranks.fetch(id) + 1
              moved = true
            end
          end
          break unless moved
        end
      end
      private_class_method :sink

      attr_reader :width, :height, :boxes, :routes

      # @param nodes [Array<Node>]
      # @param edges [Array<Edge>] none from a node to itself, and none without nodes
      # @param starts [Array] the nodes ranks start from (the first node, if none of them is one)
      # @param tops [Array] nodes above even those
      # @param bottoms [Array] nodes below all the others
      def initialize(nodes, edges, starts: [], tops: [], bottoms: [])
        if nodes.empty?
          raise ArgumentError, 'edges need nodes to run between' if edges.any?

          @width = @height = 0
          @boxes = {}
          @routes = {}
          return
        end

        @nodes = nodes
        @edges = edges
        @edges_by_id = edges.to_h { [it.id, it] }
        build(LayeredLayout.ranks(nodes.map(&:id), edges.map { [it.from, it.to] }, starts:, tops:, bottoms:))
        order
        straighten_flat
        assign_y # first: heights don't depend on positions across, and dummies are placed by them
        assign_x
        @boxes = nodes.to_h { |n| v = @v.fetch(n.id); [n.id, Placed.new(x: v.x, y: v.y)] }
        @routes = edges.to_h { [it.id, route(it, @chains.fetch(it.id))] }
      end

      private

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
        # A dummy between ranks => all of its edge's dummies.
        @mates = {}.compare_by_identity
        @chains.each do |id, (upper, *mids, lower)|
          next if upper.layer == lower.layer

          mids.each { @along[it] = [upper, lower, id]; @mates[it] = mids }
        end
        @neighbours = Hash.new { |h, k| h[k] = [] }.compare_by_identity
        @chains.each_value { |chain| chain.each_cons(2) { |p, q| @neighbours[p] << q; @neighbours[q] << p } }
      end

      def dummy(rows, edge, kind, layer, w, h)
        Vertex.new(id: [edge.id, kind, layer], kind:, w:, h:, layer:).tap { rows[layer] << it }
      end

      def order
        @layers.map! { hinted(it) }
        best = @layers.map(&:dup)
        fewest = crossings(best)
        layers = @layers.map(&:dup)
        last = layers.size - 1
        SWEEPS.times do |sweep|
          down = sweep.even?
          (down ? (1..last) : (last - 1).downto(0)).each do |l|
            ref = index(layers[down ? l - 1 : l + 1])
            layers[l] = hinted(layers[l].each_with_index.sort_by do |v, i|
              at = @neighbours[v].filter_map { ref[it] }
              [at.empty? ? i : at.sum.fdiv(at.size), i]
            end.map(&:first))
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

      # +row+ with its hinted nodes in the order of their hints, in the places
      # they had between them.
      def hinted(row)
        slots = row.each_index.select { row[it].node&.hint }
        return row if slots.size < 2

        row = row.dup
        slots.map { row[it] }.sort_by.with_index { |v, i| [v.node.hint, i] }.zip(slots).each { |v, i| row[i] = v }
        row
      end

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
          next if fixed_dx(id, a) || fixed_dx(id, b) # meets a port on its top or bottom

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
              if pass.positive? && (mates = @mates[v])
                # Where the rest of its edge's dummies are, so the edge runs
                # straight down past every rank it skips and turns only at its
                # ends: where one rank pushes a dummy aside (a wide node in the
                # way), the others follow it there.
                mates.sum(&:anchor).fdiv(mates.size) - v.anchor_dx
              elsif (upper, lower, id = @along[v])
                # Where the straight line between the edge's ends crosses the dummy's middle.
                top = upper.y + upper.h
                t = ((v.y + @layer_h.fetch(v.layer) / 2.0 - top) / (lower.y - top)).clamp(0.0, 1.0)
                x1 = (dx = fixed_dx(id, upper)) ? upper.x + dx : upper.anchor
                x2 = (dx = fixed_dx(id, lower)) ? lower.x + dx : lower.anchor
                x1 + (x2 - x1) * t - v.anchor_dx
              elsif (near = @neighbours[v]).any?
                near.sum(&:anchor).fdiv(near.size) - v.anchor_dx
              else
                v.x
              end
            end
            place_row(row, targets)
          end
        end
        snap_chains
        all = @layers.flatten
        left = all.map(&:x).min
        all.each { it.x -= left }
        @width = all.map { it.x + it.slot_w }.max
      end

      # Pulling together leaves an edge's dummies close, but not quite in
      # line where a rank pushes one aside: each edge's dummies all go where
      # one of them is, the nearest to the rest that every rank has room for
      # (Pele's +snap+), so the edge is one straight run.
      def snap_chains
        @mates.values.uniq(&:object_id).each do |mids|
          xs = mids.map(&:anchor)
          next if xs.max - xs.min < 0.01

          best = xs.sort_by { |c| [xs.sum { (it - c).abs }, c] }.find do |c|
            mids.all? { |d| fits?(d, c - d.anchor_dx) }
          end
          mids.each { |d| d.x = best - d.anchor_dx } if best
        end
      end

      # Whether +v+ fits at +x+, between its neighbours in its layer.
      def fits?(v, x)
        row = @layers[v.layer]
        i = row.index { it.equal?(v) }
        left = row[i - 1] if i.positive?
        right = row[i + 1]
        (!left || x >= left.x + sep(left, v) - 0.01) && (!right || x + sep(v, right) <= right.x + 0.01)
      end

      # How far +q+'s left must be from +p+'s, its neighbour to the left.
      def sep(p, q)
        gap = if p.dummy? && q.dummy? then DUMMY_GAP
              elsif p.dummy? || q.dummy? then PASSING_GAP
              else NODE_GAP
              end
        p.slot_w + [gap, @flat_gap[p] || 0].max
      end

      def place_row(row, targets)
        return if row.empty?

        seps = row.each_cons(2).map { |p, q| sep(p, q) }
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
          fixed = {}
          @chains.each do |id, chain|
            ends = case @flat[id]
                   in :straight then next
                   in :under
                     # Each end on the side facing the other, so the curve is a U.
                     a, _, b = chain
                     [[a, :bottom, :a, b.anchor], [b, :bottom, :b, a.anchor]]
                   else
                     [[chain.first, :bottom, :upper, chain[1].anchor], [chain.last, :top, :lower, chain[-2].anchor]]
                   end
            ends.each do |v, side, key, towards|
              if (dx = fixed_dx(id, v))
                fixed[[id, key]] = v.x + dx
                # Still in the way of the others on the side.
                sides[[v.id, side]] << [nil, v.x + dx]
              else
                sides[[v.id, side]] << [[id, key], towards]
              end
            end
          end
          sides.each_with_object(fixed) do |((id, _), list), acc|
            acc.merge!(spread(@v.fetch(id), list).reject { |key, _| key.nil? }) if list.any?(&:first)
          end
        end
      end

      # Where edge +id+ is fixed to meet +v+, from its left, if it is.
      def fixed_dx(id, v)
        edge = @edges_by_id.fetch(id)
        if v.id == edge.from then edge.from_dx
        elsif v.id == edge.to then edge.to_dx
        end
      end

      def spread(v, list)
        middle = v.x + v.w / 2.0
        return list.to_h { |key, _| [key, middle] } if v.node.round

        margin = [PORT_MARGIN, v.w / 2.0].min
        lo = v.x + margin
        hi = v.x + v.w - margin
        sorted = list.sort_by(&:last)
        # An end fixed in place (keyless) all but doesn't move.
        weights = sorted.map { |key, _| key ? 1.0 : 1000.0 }
        xs = LayeredLayout.pack(sorted.map { it.last.clamp(lo, hi) }, weights, [PORT_GAP] * (sorted.size - 1))
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
        in :straight then straight(edge)
        in :under
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
      #
      # Past the left node's +extra+ (drawn above its middle, as a statechart's
      # self-loops are) they run LOOP_CLEARANCE lower, under it. Either way the
      # label sits in the gap beyond the +extra+, which #straighten_flat sized
      # for it.
      def straight(edge)
        a = @v.fetch(edge.from)
        b = @v.fetch(edge.to)
        rightward = a.x < b.x
        left, right = rightward ? [a, b] : [b, a]
        both_ways = @edges.any? { it.from == edge.to && it.to == edge.from && @flat[it.id] == :straight }
        middle = (a.y + a.h / 2.0 + b.y + b.h / 2.0) / 2.0
        apart = both_ways ? (rightward ? -5 : 5) : 0
        y = left.node.extra.positive? ? middle + LOOP_CLEARANCE + apart / 2.0 : middle + apart
        x1 = rightward ? a.x + a.w : a.x
        x2 = rightward ? b.x : b.x + b.w
        label_x = (left.x + left.slot_w + right.x) / 2.0
        Route.new(points: [[x1, y], [x2, y]], label: [label_x, rightward ? y - 6 : y + 13],
                  anchor: 'middle', flat: :straight)
      end
    end
  end
end

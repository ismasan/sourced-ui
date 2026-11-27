# frozen_string_literal: true

require 'sidereal'
require 'sourced/ui/layered_layout'
require 'sourced/ui/edge_path'
require 'sourced/ui/flow_graph'

module Sourced
  module UI
    module Components
      # Draws a FlowGraph left to right (or top to bottom), in SVG, as a layered graph with event
      # modeling's colours: commands blue, events orange, read models green,
      # and automations (reactions) with a robot. Each node once, however
      # many lead to it, so flows branch and meet rather than queue up in a
      # timeline.
      #
      # LayeredLayout lays out top to bottom: +direction: :down+ draws what it
      # gives. Left to right (+:right+, the default), the graph goes in with
      # each box's width and height swapped, and comes out transposed, x for
      # y; the edges are drawn in the layout's space, under a transform that
      # swaps the axes.
      #
      # Cycles: LayeredLayout ranks the graph from its +starts+, and an edge
      # closing a cycle runs back against the flow, dashed. One running back
      # more than MAX_BACK ranks (or from a node to itself) isn't drawn across
      # the diagram: it ends at a proxy of its target, beside where it comes
      # from (↻ and the target's name).
      #
      # Hovering a node, or picking it (a click, or Tab, focuses it), picks out
      # its branch, what leads to it and what follows from it, and fades the
      # rest: forks joining it upstream or a descendant, and sibling branches.
      # Each node lists in +data-line+ the nodes whose branch it's on, its
      # ancestors and descendants (by edges running forward, so a loop back
      # doesn't light up the whole flow), and each edge the nodes whose
      # branch runs along it. A projector's reaction is on a branch through
      # its read model only with the event it reacts to (FlowGraph#triggers):
      # the read model may read more. A rule for each node fades what doesn't
      # list it.
      #
      # The graph's +focus+, the nodes it's built for (the reactor's steps, or a
      # machine state's event), are marked with a
      # thicker border, in their own colour, and +aria-current+. A +node_data+ hook adds more +data-+
      # attributes to a node, such as a click opening its message's schema.
      class FlowDiagram < Sidereal::Components::BaseComponent
        BOX_W = 132
        BOX_H = 56
        PROXY_H = 34
        GAP = 30           # between ranks, for the edges (the layout's label slots)
        MARGIN = 16
        CHAR_W = 6.4
        LINE_H = 13
        MAX_BACK = 2       # ranks an edge may run back before it ends at a proxy

        KIND_LABELS = { command: 'command', event: 'event', readmodel: 'read model', automation: 'reaction' }.freeze

        Proxy = Data.define(:id, :target, :from)

        # @param graph [FlowGraph]
        # @param href [#call, nil] a node's reactor's URL from its group_id, or nil for none
        # @param title [String] accessible name for the drawing
        # @param id [String] tells apart the drawings on one page
        # @param node_data [#call, nil] a FlowGraph::Node => more +data-+ attributes for its box
        # @param direction [:right, :down] the way flows run
        def initialize(graph, href: nil, title: "#{graph.group_id} flows", id: 'flow', node_data: nil, direction: :right)
          raise ArgumentError, "direction is :right or :down, not #{direction.inspect}" unless %i[right down].include?(direction)

          @graph = graph
          @across = direction == :right
          @href = href
          @node_data = node_data
          @title = title
          @id = id
          @nodes = graph.nodes.to_h { [it.id, it] }
          @short = short_paths(graph.nodes)
          plan
          @layout = layout
          trace
        end

        def view_template
          return if @graph.empty?

          # Left to right, transposed: the layout's height is the drawing's width.
          lw, lh = @across ? [@layout.height, @layout.width] : [@layout.width, @layout.height]
          w = (lw + MARGIN * 2).ceil
          h = (lh + MARGIN * 2).ceil
          svg(class: "flow-diagram flow-diagram--#{@across ? 'right' : 'down'}", viewBox: "#{-MARGIN} #{-MARGIN} #{w} #{h}", width: w, height: h,
              role: 'img', aria: { label: @title }) do |s|
            s.title { @title }
            s.style { highlight_rules }
            s.defs do
              %w[forward back].each do |kind|
                s.marker(id: "#{@id}-arrow-#{kind}", viewBox: '0 0 10 10', refX: 9, refY: 5,
                         markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse') do
                  s.path(d: 'M 0 1 L 9 5 L 0 9 z', class: "flow-diagram__arrow flow-diagram__arrow--#{kind}")
                end
              end
            end
            # The layout's space, left to right x for y.
            s.g(transform: (@across ? 'matrix(0 1 1 0 0 0)' : nil)) do
              @edges.each { draw_edge(s, it) }
            end
            @graph.nodes.each { draw_node(s, it) }
            @proxies.each { draw_proxy(s, it) }
          end
        end

        private

        # The edges to lay out, and the proxies for those running back too far.
        def plan
          ids = @graph.nodes.map(&:id)
          pairs = @graph.edges.map { [it.from, it.to] }
          ranks = LayeredLayout.ranks(ids, pairs, starts: @graph.starts)
          @proxies = []
          @edges = [] # [id, from, to, back]
          pairs.each_with_index do |(from, to), i|
            # Into an earlier rank. One within a rank runs across it, not back.
            back = ranks.fetch(to) < ranks.fetch(from)
            if from == to || (back && ranks.fetch(from) - ranks.fetch(to) > MAX_BACK)
              proxy = Proxy.new(id: "proxy:#{i}", target: to, from:)
              @proxies << proxy
              @edges << [i, from, proxy.id, false]
            else
              @edges << [i, from, to, back]
            end
          end
        end

        # Each node's token (n0, p0 for a proxy), and for each node and edge
        # the tokens of the nodes whose branch it's on (+@line+, +@edge_line+).
        def trace
          @token = @graph.nodes.each_with_index.to_h { |node, i| [node.id, "n#{i}"] }
          @proxies.each_with_index { |proxy, i| @token[proxy.id] = "p#{i}" }
          out = Hash.new { |h, k| h[k] = [] }
          into = Hash.new { |h, k| h[k] = [] }
          @edges.each do |i, from, to, back|
            next if back

            out[from] << [i, to]
            into[to] << [i, from]
          end
          @line = Hash.new { |h, k| h[k] = Set.new }
          @edge_line = Hash.new { |h, k| h[k] = Set.new }
          @token.each do |id, token|
            up_nodes, up_edges = upstream(id, into)
            down_nodes, down_edges = downstream(id, out, up_nodes)
            (up_nodes | down_nodes).each { @line[it] << token }
            (up_edges | down_edges).each { @edge_line[it] << token }
          end
        end

        # What leads to +id+, and by which edges. Back from a projector's
        # reaction, its read model is on the branch but isn't followed past:
        # what leads to the reaction is the event it reacts to.
        def upstream(id, into)
          nodes = Set[id]
          edges = Set.new
          queue = [id]
          while (at = queue.shift)
            triggers = @graph.triggers(at)
            into[at].each do |i, from|
              edges << i
              if triggers && @nodes[from]&.kind == :readmodel
                nodes << from
                into[from].each do |j, event|
                  next unless triggers.include?(event)

                  edges << j
                  queue << event if nodes.add?(event)
                end
              elsif nodes.add?(from)
                queue << from
              end
            end
          end
          [nodes, edges]
        end

        # What follows from +id+, and by which edges: from a read model into
        # a reaction of its only when what the reaction reacts to is on the
        # branch (+before+ it, or after), not just anything the model reads.
        def downstream(id, out, before)
          nodes = Set[id]
          edges = Set.new
          loop do
            added = false
            nodes.to_a.each do |from|
              out[from].each do |i, to|
                triggers = @graph.triggers(to) if @nodes[from]&.kind == :readmodel
                next if triggers && triggers.none? { before.include?(it) || nodes.include?(it) }

                edges << i
                added = true if nodes.add?(to)
              end
            end
            break unless added
          end
          [nodes, edges]
        end

        def line(id) = @line[id].to_a.join(' ')

        def edge_line(i) = @edge_line[i].to_a.join(' ')

        def highlight_rules
          rules = @token.values.flat_map do |token|
            faded = "[data-line]:not([data-line~=\"#{token}\"]) { opacity: 0.15; }"
            lit = ".flow-diagram__edge[data-line~=\"#{token}\"] { stroke: var(--slate-700); stroke-width: 1.6; }"
            [".flow-diagram:has([data-node=\"#{token}\"]:hover)", ".flow-diagram:not(:has([data-node]:hover)):has([data-node=\"#{token}\"]:focus)"]
              .flat_map { |on| ["#{on} #{faded}", "#{on} #{lit}"] }
          end
          raw safe(rules.join("\n"))
        end

        def layout
          # Left to right, swapped: across a rank is the drawing's height.
          size = ->(h) { @across ? { w: h, h: BOX_W } : { w: BOX_W, h: } }
          nodes = @graph.nodes.map { LayeredLayout::Node.new(id: it.id, **size.(BOX_H), extra: 0, round: false) }
          nodes += @proxies.map { LayeredLayout::Node.new(id: it.id, **size.(PROXY_H), extra: 0, round: false) }
          edges = @edges.map { |i, from, to, _| LayeredLayout::Edge.new(id: i, from:, to:, label_w: 0, label_h: GAP) }
          LayeredLayout.new(nodes, edges, starts: @graph.starts)
        end

        # The box's top left, in the drawing.
        def at(id)
          box = @layout.boxes.fetch(id)
          @across ? [box.y, box.x] : [box.x, box.y]
        end

        def draw_edge(s, (i, from, _to, back))
          route = @layout.routes.fetch(i)
          d = route.flat == :straight ? straight(route.points) : EdgePath.spline(route.points)
          kind = back ? 'back' : 'forward'
          s.path(d:, class: "flow-diagram__edge flow-diagram__edge--#{kind}", 'marker-end': "url(##{@id}-arrow-#{kind})",
                 data: { line: edge_line(i) })
        end

        def straight(((x1, y1), (x2, y2))) = "M #{x1.round(1)} #{y1.round(1)} L #{x2.round(1)} #{y2.round(1)}"

        def draw_node(s, node)
          x, y = at(node.id)
          classes = ['flow-diagram__node', "flow-diagram__node--#{node.kind}"]
          classes << 'is-external' unless node.own
          focus = @graph.focus.include?(node.id)
          classes << 'is-focus' if focus
          extra = @node_data&.call(node) || {}
          classes << 'is-clickable' if extra.any?
          # Messages open their schema rather than their reactor's page.
          href = !node.own && extra.empty? && @href&.call(node.group_id)
          picks = { data: { node: @token.fetch(node.id), line: line(node.id), **extra } }
          picks[:aria] = { current: 'true' } if focus
          picks[:tabindex] = 0 unless href
          group = proc do
            s.g(class: classes.join(' '), **(href ? {} : picks)) do
              s.title { ["#{node.kind}: #{node.name}", node.id, "from #{node.group_label}", *node.tags, *('what this is built for' if focus)].join("\n") }
              s.rect(x:, y:, width: BOX_W, height: BOX_H, rx: 4, class: 'flow-diagram__box')
              if node.kind == :automation
                robot(s, x + 8, y + 6)
                s.text(x: x + 26, y: y + 16, class: 'flow-diagram__kind') { KIND_LABELS.fetch(node.kind) }
              else
                s.text(x: x + 8, y: y + 15, class: 'flow-diagram__kind') { KIND_LABELS.fetch(node.kind) }
              end
              short_lines(display_name(node), BOX_W - 16, 2).each_with_index do |line, i|
                s.text(x: x + 8, y: y + 30 + i * LINE_H, class: 'flow-diagram__name') { line }
              end
              # Its foot: what else it leads to (its tags), or another reactor's name.
              if node.tags.any?
                s.text(x: x + 8, y: y + BOX_H - 6, class: 'flow-diagram__tags') { truncate(node.tags.join(' '), BOX_W - 16) }
              elsif !node.own && node.kind != :event
                s.text(x: x + 8, y: y + BOX_H - 6, class: 'flow-diagram__group') { truncate(node.group_label, BOX_W - 16) }
              end
            end
          end
          href ? s.a(href:, class: 'flow-diagram__link', **picks, &group) : group.call
        end

        def draw_proxy(s, proxy)
          x, y = at(proxy.id)
          target = @nodes.fetch(proxy.target)
          s.g(class: "flow-diagram__node flow-diagram__node--#{target.kind} flow-diagram__node--proxy", tabindex: 0,
              data: { node: @token.fetch(proxy.id), line: line(proxy.id) }) do
            s.title { "Back to #{target.name}, earlier in the flow" }
            s.rect(x:, y:, width: BOX_W, height: PROXY_H, rx: 4, class: 'flow-diagram__box')
            s.text(x: x + 8, y: y + 21, class: 'flow-diagram__name') { truncate("↻ #{display_name(target)}", BOX_W - 16) }
          end
        end

        # A robot's head, for automations: 14 wide, 13 high.
        def robot(s, x, y)
          s.g(class: 'event-model__robot', transform: "translate(#{x} #{y})") do
            s.line(x1: 7, y1: 1.5, x2: 7, y2: 4)
            s.circle(cx: 7, cy: 1.2, r: 1.2)
            s.rect(x: 1, y: 4, width: 12, height: 9, rx: 2.5)
            s.circle(cx: 4.6, cy: 8.5, r: 1.1, class: 'event-model__robot-eye')
            s.circle(cx: 9.4, cy: 8.5, r: 1.1, class: 'event-model__robot-eye')
          end
        end

        # The naming below is EventModel's (prototype: shared by copy).
        CLASS_PATH = /\b[A-Z]\w*(?:::[A-Z]\w*)+\b/

        def display_name(node)
          node.name.gsub(CLASS_PATH) { @short.fetch(it) }.sub(/\Areaction\((.+)\)\z/, 'on \1')
        end

        def short_paths(nodes)
          parts_states = nodes.select { it.transition && it.name.end_with?('::State') }.map(&:name)
          named = ->(path) { parts_states.include?(path) ? path.delete_suffix('::State') : path }
          paths = nodes.flat_map { it.name.scan(CLASS_PATH) }.uniq
          paths.to_h do |path|
            parts = named.(path).split('::')
            others = (paths - [path]).map { named.(it).split('::') }
            size = (1..parts.size).find { |n| others.none? { it.last(n) == parts.last(n) } } || parts.size
            [path, parts.last(size).join('::')]
          end
        end

        def short_lines(text, width, max)
          per_line = (width / CHAR_W).floor
          pieces = text.scan(/\S+\s*/).flat_map do |word|
            word.rstrip.length > per_line ? word.scan(/[A-Z]?[a-z0-9]+\s*|[A-Z]+(?![a-z])\s*|[^A-Za-z0-9]+/) : [word]
          end
          lines = pieces.each_with_object(['']) do |piece, acc|
            if acc.last.empty? || (acc.last + piece).rstrip.length <= per_line
              acc[-1] += piece
            else
              acc << piece
            end
          end.map(&:rstrip)
          lines = lines.flat_map { it.scan(/.{1,#{per_line}}/) }
          return lines if lines.size <= max

          lines.first(max).tap { it[-1] = "#{it[-1][0, per_line - 1]}…" }
        end

        def truncate(text, width)
          per_line = (width / (CHAR_W * 0.87)).floor
          text.length > per_line ? "#{text[0, per_line - 1]}…" : text
        end
      end
    end
  end
end

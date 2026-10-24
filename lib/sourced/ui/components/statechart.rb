# frozen_string_literal: true

require 'sidereal'
require 'sourced/ui/layered_layout'

module Sourced
  module UI
    module Components
      # Draws a Sourced::Machine as an SVG statechart, from the Hash that
      # Machine#to_h returns (Machine.to_h for the definition alone). Works for
      # any machine: it lays out whatever regions and checkpoints the Hash has.
      #
      # Layout: each region lays out its checkpoints with a LayeredLayout, top
      # to bottom from its initial position, its transitions routed between
      # them with their labels in slots of their own. A parallel checkpoint
      # draws its regions side by side inside its box, and a compound one its
      # sub-states, nested as deep as they go.
      #
      # A transition belongs to the innermost region holding both its ends: one
      # from a checkpoint nested in a compound checkpoint to that checkpoint's
      # sibling (a part's on_final) leaves through the compound's border, and one
      # from a checkpoint into a region of its own drops in from the region's
      # top, from an entry point laid out alongside the region's start. One
      # between the regions of a parallel checkpoint has no region to be laid
      # out in, and is drawn directly between its ends. An arrow from inside a
      # compound checkpoint back to it re-enters it, so it's drawn to its start.
      #
      # With an instance's status, the active checkpoints are lit, visited ones
      # marked, inactive regions dimmed, and the transitions the machine can take
      # next highlighted.
      class Statechart < Sidereal::Components::BaseComponent
        CHAR_W = 6.7       # average label glyph width at the chart's font size
        NODE_H = 30
        NODE_PAD = 14
        DOT = 8            # radius of a region's initial position
        HISTORY_R = 13     # radius of a history pseudo-state
        GAP_Y = 46         # how far an arc between neighbours may reach
        PAD = 14
        REGION_HEAD = 22
        PARALLEL_HEAD = 30
        GAP_X = 18
        LOOP = 26          # how far a self-transition loops out
        LOOP_STEP = 10     # how much further each next one on the same checkpoint does
        LOOP_RISE = 7      # how far above a checkpoint's middle its loops sit, clear of edges passing under (LayeredLayout::LOOP_CLEARANCE)
        ARC_MIN = 16       # how far the shortest arc over or under a row reaches
        EDGE_CHAR_W = 6.0  # the same, for arrow labels
        LABEL_H = 12
        UPRIGHT = 4.0      # how much more an edge's ends lean upright than its first and last stretches

        # +extra+ is room kept free to the right of a box, for its self-loops' labels.
        # A region's +layout+ places its children; +origin+ is where it starts.
        Box = Struct.new(:kind, :data, :w, :h, :x, :y, :children, :extra, :layout, :edges, :origin, keyword_init: true) do
          def cx = x + w / 2.0
          def cy = y + h / 2.0
          def right = x + w
          def bottom = y + h
        end

        # +starts+: the group_ids of the child machines it starts.
        Edge = Data.define(:from, :to, :label, :kind, :starts) do
          def initialize(starts: [], **) = super
        end
        # An edge laid out in a region, between the region's children holding its ends.
        # An edge into the region from the checkpoint it belongs to comes +from+ an
        # Entry: a point at the region's top.
        Placement = Data.define(:edge, :from, :to)
        Entry = Data.define(:index)

        ROOT = [:root].freeze

        # @param chart [Hash] Machine#to_h or Machine.to_h
        # @param title [String] accessible name for the drawing
        # @param href [#call, nil] a child machine's URL from its group_id, or nil
        #   for none: the machines a transition starts link to it
        def initialize(chart, title: nil, href: nil)
          @chart = chart
          @href = href
          @title = title || "#{chart[:machine]} statechart"
          @escalations = escalations_in(chart)
          @command_labels = MachineChart.command_labels(chart)
          @boxes = {}
          @histories = {}     # a parallel checkpoint's history node id => the checkpoint's id
          @parent_region = {} # node id => the key of the region it's in
          @region_owner = {}  # region key => the checkpoint it belongs to (nil for the root)
          @region_start = {}  # region key => its initial position
          index(chart, ROOT, nil)
          @placed = Hash.new { |h, k| h[k] = [] } # region key => its Placements
          @loops = []
          @direct = []
          (collect_edges(@chart) + escalation_edges).each { assign(it) }
          # Laid out by what's drawn: after history and re-entry targets resolve.
          @loops_on = @loops.group_by(&:from)
        end

        def view_template
          root = layout_region(@chart, ROOT, :root)
          place(root, 0, 0)

          svg(
            id: 'statechart',
            class: 'statechart',
            viewBox: "-8 -8 #{(root.w + 16).round} #{(root.h + 16).round}",
            width: (root.w + 16).round,
            height: (root.h + 16).round,
            # Its natural width, which the CSS scales from: never blown up past
            # readable, however wide the page.
            style: "--sc-w: #{(root.w + 16).round}px",
            role: 'img',
            aria: { label: @title }
          ) do |s|
            s.title { @title }
            s.defs do
              %w[arrow arrow-live].each do |name|
                s.marker(id: "sc-#{name}", viewBox: '0 0 10 10', refX: 9, refY: 5,
                         markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse') do
                  s.path(d: 'M 0 1 L 9 5 L 0 9 z', class: "statechart__#{name}")
                end
              end
            end

            draw_region_contents(s, root)
            drawings = regions(root).flat_map do |region|
              region.edges.map { |placement, route| [placement.edge, routed(region, placement, route)] }
            end
            @loops_on.each do |id, loops|
              loops.each_with_index { |edge, i| drawings << [edge, self_loop(@boxes.fetch(id), i, loops.size)] }
            end
            @direct.each { |edge| drawings << [edge, route(@boxes.fetch(edge.from), @boxes.fetch(edge.to))] }
            # Every label over every line: a line passing under one is hidden
            # by its halo there, rather than striking through it.
            drawings.each { |edge, drawing| draw_line(s, edge, drawing) }
            drawings.each { |edge, drawing| draw_label(s, edge, drawing) }
          end
        end

        private

        # ---- The chart's nesting: which region each checkpoint is in ----

        def index(region, key, owner)
          @region_owner[key] = owner
          @region_start[key] = region[:initial]
          region[:states].each_value do |state|
            @parent_region[state[:id]] = key
            case state[:type]
            in 'parallel'
              history_nodes(state).each { @histories[it[:id]] = state[:id] }
              regions_of(state).each { index(it, [:region, it[:id]], state[:id]) }
            in 'compound' then index(state, [:compound, state[:id]], state[:id])
            else nil
            end
          end
        end

        # [region key, child holding it], from the region +id+ is in outwards.
        def lineage(id)
          out = []
          while id
            key = @parent_region.fetch(id)
            out << [key, id]
            id = @region_owner.fetch(key)
          end
          out
        end

        # A self-transition loops on its checkpoint. One from a checkpoint into
        # a region of its own enters it from the top. Any other goes to the
        # innermost region holding both its ends as different children, or,
        # between a parallel checkpoint's regions, straight between them.
        def assign(edge)
          return @loops << edge if edge.from == edge.to

          to_lineage = lineage(edge.to)
          into, to = to_lineage.find { |key, _| @region_owner.fetch(key) == edge.from }
          return @placed[into] << Placement.new(edge:, from: Entry.new(@placed[into].size), to:) if into

          targets = to_lineage.to_h
          lineage(edge.from).each do |key, from|
            next unless (to = targets[key])
            return @direct << edge if from == to

            return @placed[key] << Placement.new(edge:, from:, to:)
          end
          @direct << edge
        end

        # ---- Layout: sizes, relative to each box's own origin ----

        def layout_region(region, key, kind)
          children = region[:states].values.map { |state| layout_node(state) }
          # Joins first, so ranks follow the main path, then commands in definition order.
          placements = @placed[key].each_with_index.sort_by { |p, i| [p.edge.kind == :done ? 0 : 1, i] }.map(&:first)
          nodes = children.map do |box|
            LayeredLayout::Node.new(id: box.data[:id], w: box.w, h: box.h, extra: box.extra.to_i,
                                    round: (box.kind in :initial | :history))
          end
          entries = placements.map(&:from).grep(Entry)
          nodes += entries.map { LayeredLayout::Node.new(id: it, w: 2, h: 2, extra: 0, round: true) }
          edges = placements.each_with_index.map do |p, i|
            LayeredLayout::Edge.new(id: i, from: p.from, to: p.to, label_w: text_width(p.edge.label) + 4, label_h: LABEL_H)
          end
          layout = LayeredLayout.new(nodes, edges, starts: [region[:initial]], tops: entries)

          head = kind == :region ? REGION_HEAD : 0
          pad = kind == :region ? PAD : 0
          name_w = kind == :region ? region[:key].to_s.length * CHAR_W + 20 : 0
          Box.new(kind:, data: region, children:, layout:,
                  edges: placements.each_with_index.map { |p, i| [p, layout.routes.fetch(i)] },
                  w: [layout.width + pad * 2, name_w].max, h: head + layout.height + pad * 2)
        end

        def layout_node(state)
          size = case state[:type]
                 in 'initial'
                   { w: DOT * 2, h: DOT * 2, children: [] }
                 in 'history'
                   { w: HISTORY_R * 2, h: HISTORY_R * 2, children: [] }
                 in 'parallel'
                   regions = regions_of(state).map { |region| layout_region(region, [:region, region[:id]], :region) }
                   w = regions.sum(&:w) + GAP_X * [regions.size - 1, 0].max + PAD * 2
                   w = [w, label_width(state) + PAD * 2].max
                   { w:, h: PARALLEL_HEAD + (regions.map(&:h).max || 0) + PAD, children: regions }
                 in 'compound'
                   inner = layout_region({ id: state[:id], key: state[:key], initial: state[:initial], states: state[:states] },
                                         [:compound, state[:id]], :compound_region)
                   head = label_width(state) + compound_name(state).length * CHAR_W + PAD * 2
                   { w: [inner.w + PAD * 2, head].max, h: PARALLEL_HEAD + inner.h + PAD, children: [inner] }
                 else
                   { w: label_width(state), h: NODE_H, children: [] }
                 end
          loops = @loops_on.fetch(state[:id], [])
          extra = loops.any? ? LOOP + LOOP_STEP * (loops.size - 1) + loops.map { text_width(it.label) }.max + 8 : 0
          @boxes[state[:id]] = Box.new(**size, kind: state[:type].to_sym, data: state, extra:)
        end

        def label_width(state)
          badge = timer_badge(state)
          timer = badge ? text_width(badge) + 16 : 0
          [(state[:key].length * CHAR_W) + NODE_PAD * 2 + timer, 72].max
        end

        # A transition its own state's timer fires says so: `⏱ 15m / Expire`.
        def timed_label(state, transition)
          label = transition_label(transition)
          delays = state[:after].select { it[:dispatches].include?(transition[:event]) }.map { MachineChart.delay_label(it[:delay]) }
          delays.any? ? "⏱ #{delays.join(', ')} / #{label}" : label
        end

        # The timers whose commands no arrow from the state carries (another
        # state takes them), on the state itself: `⏱ 2h / Reopen`.
        def timer_badge(state)
          untaken = state[:after].filter_map do |timer|
            rest = timer[:dispatches].reject { state[:on].key?(it) }
            MachineChart::Timer.new(delay: timer[:delay], commands: rest.map { @command_labels.fetch(it) }).label if rest.any?
          end
          untaken.any? ? "⏱ #{untaken.join(', ')}" : nil
        end

        # [label, target id] for each transition the machine takes by itself from
        # +state+: its `done` joins and `always` transitions, with their guards.
        # A single unguarded `done` is just its target's id.
        def eventless(state)
          dones = case state[:on_done]
                  in String => target then [['done', target]]
                  in Array => list then list.map { |d| [guarded('done', d[:guard]), d[:target]] }
                  else []
                  end
          dones + Array(state[:always]).map { |a| [guarded('always', a[:guard]), a[:target]] }
        end

        def guarded(label, guard) = guard ? "#{label} [#{guard.to_s.split('::').last}]" : label

        # An event-triggered transition (`on Event`) reads as such, and one that
        # starts child machines says which: `LogIn / starts Session`.
        def transition_label(transition)
          label = transition[:kind] == 'event' ? "on #{transition[:label]}" : transition[:label]
          starts = Array(transition[:starts]).map { machine_name(it) }
          starts.any? ? "#{label} / starts #{starts.join(', ')}" : label
        end

        # A child machine's short name from its group id: the last segment,
        # camel-cased back (+trips.leg_machine+ => +LegMachine+).
        def machine_name(group_id) = group_id.split(/::|\./).last.split('_').reject(&:empty?).map { it[0].upcase + it[1..] }.join

        def text_width(label) = label.length * EDGE_CHAR_W

        # ---- Placement: absolute positions ----

        def place(box, x, y)
          box.x = x
          box.y = y

          case box.kind
          in :root | :region | :compound_region
            head = box.kind == :region ? REGION_HEAD : 0
            pad = box.kind == :region ? PAD : 0
            # Centred, in a region its name makes wider than its layout.
            box.origin = [x + (box.w - box.layout.width) / 2.0, y + head + pad]
            box.children.each do |child|
              at = box.layout.boxes.fetch(child.data[:id])
              place(child, box.origin[0] + at.x, box.origin[1] + at.y)
            end
          in :parallel | :compound
            used = box.children.sum(&:w) + GAP_X * [box.children.size - 1, 0].max
            col_x = x + (box.w - used) / 2.0
            box.children.each do |region|
              place(region, col_x, y + PARALLEL_HEAD)
              col_x += region.w + GAP_X
            end
          else nil
          end
        end

        # Every region box under +box+, +box+ first if it's one.
        def regions(box)
          own = (box.kind in :root | :region | :compound_region) ? [box] : []
          own + box.children.flat_map { regions(it) }
        end

        # ---- Drawing ----

        def draw_region_contents(s, region)
          region.children.each { |child| draw_node(s, child) }
        end

        def draw_region(s, region)
          status = region.data[:status]
          classes = ['statechart__region']
          classes << 'is-inactive' if status && !status[:active]
          classes << 'is-done' if status&.dig(:done)

          s.g(class: classes.join(' '), id: "sc-region-#{region.data[:id]}") do
            s.rect(x: region.x, y: region.y, width: region.w, height: region.h, rx: 10, class: 'statechart__region-box')
            s.text(x: region.x + 10, y: region.y + 15, class: 'statechart__region-name') { region.data[:key] }
            draw_region_contents(s, region)
          end
        end

        def draw_node(s, box)
          state = box.data
          status = state[:status]
          classes = ['statechart__node', "statechart__node--#{state[:type]}"]
          classes << 'is-active' if status&.dig(:active)
          classes << 'is-visited' if status&.dig(:visited) && !status[:active]

          s.g(class: classes.join(' '), id: "sc-#{node_dom_id(state[:id])}") do
            s.title { node_title(state) }
            case box.kind
            in :initial
              s.circle(cx: box.cx, cy: box.cy, r: DOT, class: 'statechart__dot')
            in :history
              s.circle(cx: box.cx, cy: box.cy, r: HISTORY_R, class: 'statechart__history')
              s.text(x: box.cx, y: box.cy + 4, class: 'statechart__label', 'text-anchor': 'middle') do
                state[:history] == 'deep' ? 'H*' : 'H'
              end
            in :parallel
              s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 14, class: 'statechart__box')
              s.text(x: box.x + 14, y: box.y + 20, class: 'statechart__label') { state[:key] }
              s.text(x: box.right - 14, y: box.y + 20, class: 'statechart__hint', 'text-anchor': 'end') { 'parallel' }
              box.children.each { |region| draw_region(s, region) }
            in :compound
              s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 14, class: 'statechart__box')
              s.text(x: box.x + 14, y: box.y + 20, class: 'statechart__label') { state[:key] }
              s.text(x: box.right - 14, y: box.y + 20, class: 'statechart__hint', 'text-anchor': 'end') { compound_name(state) }
              box.children.each { |region| draw_region_contents(s, region) }
            else
              s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 8, class: 'statechart__box')
              if box.kind == :final
                s.rect(x: box.x + 3, y: box.y + 3, width: box.w - 6, height: box.h - 6, rx: 6, class: 'statechart__final-ring')
              end
              badge = timer_badge(state)
              label_x = badge ? box.x + NODE_PAD : box.cx
              s.text(x: label_x, y: box.cy + 4, class: 'statechart__label', 'text-anchor': badge ? 'start' : 'middle') { state[:key] }
              s.text(x: box.right - NODE_PAD, y: box.cy + 4, class: 'statechart__timer', 'text-anchor': 'end') { badge } if badge
            end
          end
        end

        def node_title(state)
          return 'initial position' if state[:type] == 'initial'
          return "#{state[:history]} history (#{state[:id]})" if state[:type] == 'history'
          text = "#{state[:key]} (#{state[:id]})"
          if (entered = state.dig(:status, :entered_by))
            text += " — entered #{Time.iso8601(entered[:at]).localtime.strftime('%H:%M:%S')}"
          end
          text
        end

        def collect_edges(region, edges = [])
          region[:states].each_value do |state|
            live = state.dig(:status, :active)
            Array(state[:on]&.values).each do |transition|
              label = timed_label(state, transition)
              if transition[:targets].empty?
                edges << Edge.new(from: state[:id], to: state[:id], label:, kind: live ? :data_live : :data,
                                  starts: Array(transition[:starts]))
              else
                transition[:targets].each do |target|
                  to, label = @histories.key?(target) ? [@histories[target], "#{label} (#{history_mark(target)})"] : [target, label]
                  edges << Edge.new(from: state[:id], to: reentry(state[:id], to), label:, kind: live ? :live : :command,
                                    starts: Array(transition[:starts]))
                end
              end
            end
            eventless(state).each { |label, target| edges << Edge.new(from: state[:id], to: target, label:, kind: :done) }
            case state[:type]
            in 'parallel' then regions_of(state).each { |child| collect_edges(child, edges) }
            in 'compound' then collect_edges(state, edges)
            else nil
            end
          end
          edges
        end

        # How parts escalate: each mount's root finals, which
        # +on_final+ maps onto the mounting machine's checkpoints, as [from id, to id].
        def escalations_in(region)
          region[:states].each_value.flat_map do |state|
            mounted = Array(state[:mounts]).flat_map { |mount| mount[:on_final].to_a }
            children = state[:type] == 'parallel' ? regions_of(state) : Array(state[:states]&.values)
            mounted + children.flat_map do |child|
              state[:type] == 'parallel' ? escalations_in(child) : escalations_in({ states: { child[:key] => child } })
            end
          end
        end

        def escalation_edges
          @escalations.map { |from, to| Edge.new(from:, to:, label: 'on_final', kind: :done) }
        end

        # A parallel checkpoint's regions. Its history node, if anything targets
        # one, sits among them in +states+; it isn't drawn: arrows to it go to
        # the checkpoint, marked (H) or (H*).
        def regions_of(state) = state[:states].values.reject { it[:type] == 'history' }
        def history_nodes(state) = state[:states].values.select { it[:type] == 'history' }
        def history_mark(id) = id.end_with?('$deep_history') ? 'H*' : 'H'

        # A target that contains +from+ is re-entered at the start of the region
        # +from+ is in: a compound checkpoint's, or a parallel one's region.
        def reentry(from, target)
          key, = lineage(from).find { |k, _| @region_owner.fetch(k) == target }
          (key && @region_start.fetch(key)) || target
        end

        # An edge its region laid out: the region's route, from and to the
        # children holding its ends, reaching on into them for ends nested deeper.
        def routed(region, placement, route)
          ox, oy = region.origin
          points = route.points.map { |x, y| [ox + x, oy + y] }
          label = route.label && [ox + route.label[0], oy + route.label[1]]
          edge = placement.edge
          flat = route.flat
          if Entry === placement.from
            # From the region's top edge: its border, or its compound's head.
            points.unshift([points.first[0], region.y - (region.kind == :region ? 0 : 6)])
          elsif edge.from != placement.from
            points.unshift(edge_point(@boxes.fetch(edge.from), points.first))
            flat = nil
          end
          if edge.to != placement.to
            points.push(edge_point(@boxes.fetch(edge.to), points.last))
            flat = nil
          end
          [path(points, flat), [*label, route.anchor]]
        end

        # Where a line towards +point+ leaves or reaches +box+: its bottom or top.
        def edge_point(box, point)
          [box.cx, point[1] > box.cy ? box.bottom : box.y]
        end

        def path(points, flat)
          case flat
          in :straight
            (x1, y1), (x2, y2) = points
            "M #{f x1} #{f y1} L #{f x2} #{f y2}"
          else spline(points) # under a row too: through its lowest point
          end
        end

        # A smooth curve through every point, as Bézier segments: through each
        # point in between heading from the point before to the one after, so it
        # sweeps rather than bending at each, and at its ends heading along its
        # first and last stretches, so arrowheads point the way the line comes
        # in. Ends lean upright (UPRIGHT), meeting boxes from above or below.
        # Each segment's control points reach a third of its own length along
        # those headings, so a short segment beside a long one doesn't
        # overshoot, and stay level with the segment, so it never doubles back
        # up or down.
        def spline(points)
          last = points.size - 1
          headings = points.each_index.map do |i|
            dx, dy = case i
                     in 0 then [points[1][0] - points[0][0], (points[1][1] - points[0][1]) * UPRIGHT]
                     in ^last then [points[last][0] - points[last - 1][0], (points[last][1] - points[last - 1][1]) * UPRIGHT]
                     else [points[i + 1][0] - points[i - 1][0], points[i + 1][1] - points[i - 1][1]]
                     end
            length = Math.hypot(dx, dy)
            length.zero? ? [0.0, 0.0] : [dx / length, dy / length]
          end
          points.each_cons(2).with_index.reduce("M #{f points[0][0]} #{f points[0][1]}") do |d, (((x1, y1), (x2, y2)), i)|
            reach = Math.hypot(x2 - x1, y2 - y1) / 3
            (hx1, hy1), (hx2, hy2) = headings[i], headings[i + 1]
            low, high = [y1, y2].minmax
            c1y = (y1 + hy1 * reach).clamp(low, high)
            c2y = (y2 - hy2 * reach).clamp(low, high)
            d + " C #{f(x1 + hx1 * reach)} #{f c1y}, #{f(x2 - hx2 * reach)} #{f c2y}, #{f x2} #{f y2}"
          end
        end

        # A +drawing+ is [path, [label x, label y, anchor]]. Its line and label
        # are drawn apart, each in a group with the edge's classes.
        def draw_line(s, edge, (d, _))
          s.g(class: edge_classes(edge)) do
            s.path(d:, 'marker-end': "url(#sc-#{live?(edge) ? 'arrow-live' : 'arrow'})")
          end
        end

        def draw_label(s, edge, (_, (x, y, anchor)))
          s.g(class: edge_classes(edge)) do
            s.text(x:, y:, class: 'statechart__edge-label', 'text-anchor': anchor) do
              linked = @href && edge.starts.any?
              linked ? label_with_links(s, edge) : edge.label
            end
          end
        end

        # The label, the machines it starts (`LogIn / starts Session`) each a
        # link to its page where +href+ gives one.
        def label_with_links(s, edge)
          names = edge.starts.map { machine_name(it) }
          starting = " / starts #{names.join(', ')}"
          at = edge.label.index(starting) || raise(ArgumentError, "#{edge.label.inspect} doesn't say it #{starting.strip}")
          s.plain "#{edge.label[0...at]} / starts "
          edge.starts.zip(names).each_with_index do |(id, name), i|
            s.plain ', ' if i.positive?
            if (url = @href.call(id))
              s.a(href: url, class: 'statechart__link') { s.tspan { name } }
            else
              s.plain name
            end
          end
          s.plain edge.label[(at + starting.length)..]
        end

        def live?(edge) = (edge.kind in :live | :data_live)

        def edge_classes(edge)
          ['statechart__edge', "statechart__edge--#{edge.kind}", ('is-live' if live?(edge))].compact.join(' ')
        end

        # A path between two boxes no region lays out (between a parallel
        # checkpoint's regions), and where its label goes: [path, [x, y, anchor]].
        def route(from, to)
          if to.y >= from.bottom - 1
            # Straight down where the boxes overlap horizontally, so arrows
            # leaving a wide box don't share a starting point.
            x1 = to.cx.clamp(from.x + 12, [from.right - 12, from.x + 12].max)
            x2 = from.cx.clamp(to.x + 12, [to.right - 12, to.x + 12].max)
            x2 = x1 if x1.between?(to.x + 12, to.right - 12)
            x1 = from.cx if from.kind == :initial
            x2 = to.cx if to.kind == :initial
            y1 = from.bottom
            y2 = to.y
            bend = [(y2 - y1) / 2.0, 18].max
            path = "M #{f x1} #{f y1} C #{f x1} #{f(y1 + bend)}, #{f x2} #{f(y2 - bend)}, #{f x2} #{f y2}"
            label_x = (x1 + x2) / 2.0
            [path, [label_x + 6, (y1 + y2) / 2.0 + 4, 'start']]
          elsif blocked?(from, to)
            arc(from, to)
          else
            # Beside, or above: leave from the side facing the target.
            rightward = to.cx >= from.cx
            x1 = rightward ? from.right : from.x
            x2 = rightward ? to.x : to.right
            y1 = from.cy
            y2 = to.cy
            dx = (x2 - x1) / 2.0
            path = "M #{f x1} #{f y1} C #{f(x1 + dx)} #{f y1}, #{f(x2 - dx)} #{f y2}, #{f x2} #{f y2}"
            [path, [(x1 + x2) / 2.0, (y1 + y2) / 2.0 - 6, 'middle']]
          end
        end

        # Whether a straight arrow between two boxes beside each other would run
        # through another box: one between them, level with them, that holds
        # neither.
        def blocked?(from, to)
          return false unless (from.cy - to.cy).abs < 1

          left, right = [from, to].minmax_by(&:cx)
          @boxes.each_value.any? do |box|
            !box.equal?(from) && !box.equal?(to) &&
              box.x < right.x && box.right > left.right &&
              box.y < from.cy && box.bottom > from.cy &&
              !contains?(box, from) && !contains?(box, to)
          end
        end

        def contains?(outer, inner)
          outer.x <= inner.x && outer.right >= inner.right && outer.y <= inner.y && outer.bottom >= inner.bottom
        end

        # Over the row for an arrow to the right, under it for one to the left,
        # so arrows each way between the same boxes don't meet. Wider arcs go
        # higher, so arcs over the same row nest rather than overlap.
        def arc(from, to)
          rightward = to.cx > from.cx
          dir = rightward ? -1 : 1
          x1 = from.cx + (rightward ? 1 : -1) * from.w / 4.0
          x2 = to.cx - (rightward ? 1 : -1) * to.w / 4.0
          y = rightward ? from.y : from.bottom
          height = [ARC_MIN + (x2 - x1).abs * 0.06, GAP_Y - 6].min
          pull = height / 0.75 # a cubic reaches 3/4 of the way to its control points
          path = "M #{f x1} #{f y} C #{f x1} #{f(y + dir * pull)}, #{f x2} #{f(y + dir * pull)}, #{f x2} #{f y}"
          label_y = y + dir * height + (rightward ? -4 : 12)
          [path, [(x1 + x2) / 2.0, label_y, 'middle']]
        end

        # The +index+th of a checkpoint's +count+ self-loops: nested, each
        # reaching further out, their labels stacked beside the outermost.
        def self_loop(box, index, count)
          x = box.right
          y = case box.kind
              in :parallel | :compound then box.y + 18
              in :initial | :history then box.cy
              else box.cy - LOOP_RISE
              end
          out = LOOP + LOOP_STEP * index
          path = "M #{f x} #{f(y - 6)} C #{f(x + out)} #{f(y - 18)}, #{f(x + out)} #{f(y + 18)}, #{f x} #{f(y + 6)}"
          label_y = y + 4 + (index - (count - 1) / 2.0) * 13
          [path, [x + LOOP + LOOP_STEP * (count - 1) - 2, label_y, 'start']]
        end

        # The part's name: its checkpoints are defined in it.
        def compound_name(state) = state[:mounts].first[:src].split('::').last

        def f(n) = n.round(1)

        def node_dom_id(id) = id.to_s.gsub(/[^A-Za-z0-9_-]/, '-')
      end
    end
  end
end

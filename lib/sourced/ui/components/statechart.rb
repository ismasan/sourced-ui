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
      # sibling (a part's on_final) leaves through a port in the compound's
      # border, laid out inside it up to the port and outside it from there
      # (see Placement; the regions are laid out twice, the second time with
      # each region's ports in the order of where their edges go). One
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
        MARGIN = 8         # around everything drawn
        ACTION_H = 14      # a line of a checkpoint's entry and exit actions
        ACTION_TOP = 4     # room above its first one, under the checkpoint's name
        ACTION_BOTTOM = 5  # and below its last, clear of the box's border

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
        #
        # An edge between a checkpoint nested in a compound or parallel one and
        # one outside it crosses its border at a Port, as Pele (pele.run) lays
        # out its groups: it's laid out in pieces, a region at a time, one in
        # each region it crosses, each piece inside a region from or to a port
        # at the region's top or bottom (whichever faces where the edge goes
        # on), and the piece outside meeting the border right there
        # (+from_port+, +to_port+: the port inside its +from+ or +to+).
        Placement = Data.define(:edge, :from, :to, :from_port, :to_port) do
          def initialize(from_port: nil, to_port: nil, **) = super
          def port_leg? = Port === from || Port === to
        end
        Entry = Data.define(:index)
        Port = Data.define(:serial)

        ROOT = [:root].freeze

        # @param chart [#to_h] a Sourced::Machine instance or class, or the Hash its #to_h returns
        # @param title [String] accessible name for the drawing
        # @param href [#call, nil] a child machine's URL from its group_id, or nil
        # @param command_href [#call, nil] the URL for a command an entry or exit
        #   action dispatches, from its type (the page of the reactor that
        #   handles it), or nil for none
        #   for none: the machines a transition starts link to it
        def initialize(chart, title: nil, href: nil, command_href: nil)
          @chart = chart.to_h
          @href = href
          @command_href = command_href
          @title = title || "#{@chart[:machine]} statechart"
          @escalations = escalations_in(@chart)
          @command_labels = MachineChart.command_labels(@chart)
          @boxes = {}
          @histories = {}     # a parallel checkpoint's history node id => the checkpoint's id
          @parent_region = {} # node id => the key of the region it's in
          @region_owner = {}  # region key => the checkpoint it belongs to (nil for the root)
          @region_start = {}  # region key => its initial position
          index(@chart, ROOT, nil)
          @placed = Hash.new { |h, k| h[k] = [] } # region key => its Placements
          @loops = []
          @direct = []
          (collect_edges(@chart) + escalation_edges).each { assign(it) }
          @ports = 0
          @port_side = {}   # Port => :top or :bottom of its region
          @port_region = {} # Port => the region Box it's laid out in
          add_ports
          # Laid out by what's drawn: after history and re-entry targets resolve.
          @loops_on = @loops.group_by(&:from)
        end

        def view_template
          plan_ports(@chart, ROOT)
          @port_hint = {}
          root = layout_region(@chart, ROOT, :root)
          place(root, 0, 0)
          if @ports.positive?
            # Again, with each region's ports in the order of where their
            # edges go outside it, so they don't cross on the way there.
            @port_hint = port_hints(root)
            root = layout_region(@chart, ROOT, :root)
            place(root, 0, 0)
          end

          drawings = stitched(regions(root).flat_map { |region| region.edges.map { |placement, route| [placement, region, route] } })
          @loops_on.each do |id, loops|
            loops.each_with_index { |edge, i| drawings << [edge, self_loop(@boxes.fetch(id), i, loops.size)] }
          end
          @direct.each { |edge| drawings << [edge, route(@boxes.fetch(edge.from), @boxes.fetch(edge.to))] }
          drawings = stack_labels(drawings)

          # What's drawn, not just the boxes laid out: an edge routed around
          # the outside, or its label, reaches past them.
          x1, y1, x2, y2 = bounds(root, drawings)
          w = (x2 - x1 + MARGIN * 2).round
          h = (y2 - y1 + MARGIN * 2).round

          svg(
            id: 'statechart',
            class: 'statechart',
            viewBox: "#{f(x1 - MARGIN)} #{f(y1 - MARGIN)} #{w} #{h}",
            width: w,
            height: h,
            # Its natural width, which the CSS scales from: never blown up past
            # readable, however wide the page.
            style: "--sc-w: #{w}px",
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

        # An edge from or to a checkpoint nested deeper than the children its
        # region holds gets a piece in each region between, through a Port.
        def add_ports
          @placed.keys.each do |key|
            @placed[key].map! do |p|
              next p if Entry === p.from || p.port_leg?

              from_port = port_legs(p.edge, p.edge.from, key, :out) if p.edge.from != p.from
              to_port = port_legs(p.edge, p.edge.to, key, :in) if p.edge.to != p.to
              p.with(from_port:, to_port:)
            end
          end
        end

        # The pieces of +edge+ inside the regions between +id+ (an end of it)
        # and the region +key+, the innermost first, each from (+:out+) or to
        # (+:in+) a port of its own. Returns the outermost port.
        def port_legs(edge, id, key, way)
          inner = nil
          lineage(id).take_while { |k, _| k != key }.each do |k, child|
            port = Port.new(serial: @ports += 1)
            @placed[k] << if way == :out
                            Placement.new(edge:, from: child, to: port, from_port: inner)
                          else
                            Placement.new(edge:, from: port, to: child, to_port: inner)
                          end
            inner = port
          end
          inner
        end

        # Which side of its region each port goes on: the one facing where the
        # edge goes on, in the region outside, by the ranks there; so each
        # region's ranks first, outermost first. Ranks depend on the graph
        # alone, so they're known before any sizes.
        def plan_ports(region, key)
          placements = ordered(key)
          ids, edges, options = rank_input(region, placements)
          ranks = LayeredLayout.ranks(ids, edges, **options)
          placements.each do |p|
            @port_side[p.from_port] = ranks.fetch(p.from) <= ranks.fetch(p.to) ? :bottom : :top if p.from_port
            @port_side[p.to_port] = ranks.fetch(p.from) < ranks.fetch(p.to) ? :top : :bottom if p.to_port
          end
          region[:states].each_value do |state|
            case state[:type]
            in 'parallel' then regions_of(state).each { plan_ports(it, [:region, it[:id]]) }
            in 'compound' then plan_ports(state, [:compound, state[:id]])
            else nil
            end
          end
        end

        # A region's placements: joins first, so ranks follow the main path,
        # then commands in definition order.
        def ordered(key) = @placed[key].each_with_index.sort_by { |p, i| [p.edge.kind == :done ? 0 : 1, i] }.map(&:first)

        # [ids, edges, options] for LayeredLayout.ranks, as #layout_region lays
        # the region out.
        def rank_input(region, placements)
          entries = placements.map(&:from).grep(Entry)
          ports = placements.flat_map { [it.from, it.to] }.grep(Port)
          ids = region[:states].values.map { it[:id] } + entries + ports
          [ids, placements.map { [it.from, it.to] },
           { starts: [region[:initial]], tops: entries + ports.select { @port_side.fetch(it) == :top },
             bottoms: ports.select { @port_side.fetch(it) == :bottom } }]
        end

        # ---- Layout: sizes, relative to each box's own origin ----

        def layout_region(region, key, kind)
          children = region[:states].values.map { |state| layout_node(state) }
          placements = ordered(key)
          nodes = children.map do |box|
            LayeredLayout::Node.new(id: box.data[:id], w: box.w, h: box.h, extra: box.extra.to_i,
                                    round: (box.kind in :initial | :history))
          end
          ids, _, options = rank_input(region, placements)
          nodes += ids.grep(Entry).map { LayeredLayout::Node.new(id: it, w: 2, h: 2, extra: 0, round: true) }
          ports = ids.grep(Port)
          nodes += ports.map { LayeredLayout::Node.new(id: it, w: 2, h: 2, extra: 0, round: true, hint: @port_hint[it]) }
          edges = placements.each_with_index.map do |p, i|
            # Only the piece between the edge's own region's children is labelled.
            label_w = p.port_leg? ? 0 : text_width(p.edge.label) + 4
            LayeredLayout::Edge.new(id: i, from: p.from, to: p.to, label_w:, label_h: p.port_leg? ? 0 : LABEL_H,
                                    from_dx: p.from_port && port_dx(@boxes.fetch(p.from), p.from_port),
                                    to_dx: p.to_port && port_dx(@boxes.fetch(p.to), p.to_port))
          end
          layout = LayeredLayout.new(nodes, edges, **options)

          head = kind == :region ? REGION_HEAD : 0
          pad = kind == :region ? PAD : 0
          name_w = kind == :region ? region[:key].to_s.length * CHAR_W + 20 : 0
          Box.new(kind:, data: region, children:, layout:,
                  edges: placements.each_with_index.map { |p, i| [p, layout.routes.fetch(i)] },
                  w: [layout.width + pad * 2, name_w].max, h: head + layout.height + pad * 2).tap do |box|
            ports.each { @port_region[it] = box }
          end
        end

        # Port => how far across the edge through it heads, once out of the
        # checkpoint it's in (where the piece outside turns to first), from
        # the left of the layout of the region the port is in.
        def port_hints(root)
          regions(root).each_with_object({}) do |region, hints|
            region.edges.each do |p, route|
              points, = absolute(region, route)
              hints[p.from_port] = points[1][0] - @port_region.fetch(p.from_port).origin[0] if p.from_port
              hints[p.to_port] = points[-2][0] - @port_region.fetch(p.to_port).origin[0] if p.to_port
            end
          end
        end

        # How far from +owner+'s left (a compound or parallel checkpoint) its
        # +port+ is, as #place places the regions inside it.
        def port_dx(owner, port)
          used = owner.children.sum(&:w) + GAP_X * [owner.children.size - 1, 0].max
          col = (owner.w - used) / 2.0
          region = @port_region.fetch(port)
          owner.children.each do |child|
            return col + (child.w - child.layout.width) / 2.0 + child.layout.boxes.fetch(port).x + 1 if child.equal?(region)

            col += child.w + GAP_X
          end
          raise ArgumentError, "#{port.inspect} isn't inside #{owner.data[:id]}"
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
                   w = [w, label_width(state) + PAD * 2, actions_width(state)].max
                   { w:, h: head_height(state) + (regions.map(&:h).max || 0) + PAD, children: regions }
                 in 'compound'
                   inner = layout_region({ id: state[:id], key: state[:key], initial: state[:initial], states: state[:states] },
                                         [:compound, state[:id]], :compound_region)
                   head = label_width(state) + compound_name(state).length * CHAR_W + PAD * 2
                   { w: [inner.w + PAD * 2, head, actions_width(state)].max, h: head_height(state) + inner.h + PAD, children: [inner] }
                 else
                   { w: [label_width(state), actions_width(state)].max, h: NODE_H + actions_height(state), children: [] }
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

        # A checkpoint's entry and exit actions, a line each, UML's way:
        # `entry / Notify`, `exit / WorkQueue::Release`. What an action
        # dispatches is named as on the arrows, if it's this machine's; another
        # reactor's command in full, so it reads as going elsewhere (see
        # #command_name). One that dispatches nothing it declares isn't drawn.
        def action_lines(state) = actions(state).map { |kind, types| "#{kind} / #{types.map { command_name(it) }.join(', ')}" }

        # [kind, the command types it dispatches] for each action that
        # dispatches any: +entry+s, then +exit+s.
        def actions(state)
          %i[entry exit].flat_map do |kind|
            Array(state[kind]).filter_map do |action|
              types = Array(action[:dispatches])
              [kind, types] if types.any?
            end
          end
        end

        # This machine's command as its arrows label it; another's by its
        # class's full name (+Expenses::Expense::ImportExpense+), or else its
        # type (+billing.charge_card+), for one not registered here.
        def command_name(type) = @command_labels.fetch(type) { foreign_command_name(type) }

        def foreign_command_name(type)
          klass = Sourced::Message.registry[type] if defined?(Sourced::Message) && Sourced::Message.respond_to?(:registry)
          klass&.name || type
        end

        # How much taller its actions make a checkpoint, and how wide.
        def actions_height(state)
          lines = action_lines(state)
          lines.empty? ? 0 : ACTION_TOP + lines.size * ACTION_H + ACTION_BOTTOM
        end

        def actions_width(state)
          lines = action_lines(state)
          lines.empty? ? 0 : lines.map { text_width(it) }.max + NODE_PAD * 2
        end

        # A parallel or compound checkpoint's head: its name, then its actions.
        def head_height(state) = PARALLEL_HEAD + actions_height(state)

        # Its actions, under its name, from +top+: each command a link to
        # where +command_href+ says, if it says.
        def draw_actions(s, box, top)
          actions(box.data).each_with_index do |(kind, types), i|
            s.text(x: box.x + NODE_PAD, y: top + ACTION_TOP + (i + 1) * ACTION_H - 3, class: 'statechart__action') do
              s.plain "#{kind} / "
              types.each_with_index do |type, j|
                s.plain ', ' if j.positive?
                url = @command_href&.call(type)
                if url
                  s.a(href: url, class: 'statechart__link') { s.tspan { command_name(type) } }
                else
                  s.plain command_name(type)
                end
              end
            end
          end
        end

        # A transition its own state's timer fires says so: `⏱ 15m / Expire`.
        def timed_label(state, transition)
          label = transition_label(transition)
          delays = state[:after].select { it[:dispatches].include?(transition[:event]) }.map { MachineChart.delay_label(MachineChart.timer_delay(it)) }
          delays.any? ? "⏱ #{delays.join(', ')} / #{label}" : label
        end

        # The timers whose commands no arrow from the state carries (another
        # state takes them), on the state itself: `⏱ 2h / Reopen`.
        def timer_badge(state)
          untaken = state[:after].filter_map do |timer|
            rest = timer[:dispatches].reject { state[:on].key?(it) }
            MachineChart::Timer.new(delay: MachineChart.timer_delay(timer), commands: rest.map { @command_labels.fetch(it) }).label if rest.any?
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
              place(region, col_x, y + head_height(box.data))
              col_x += region.w + GAP_X
            end
          else nil
          end
        end

        # Edges between the same two checkpoints share a line, and their labels
        # its one place (+rechecking_date+ to +cleaning+ on CompleteDateRecheck
        # or FailDateRecheck): each label after the first at a place is moved
        # up a line, so they read as a list. Each edge keeps its own drawing, so
        # an instance still lights the one it took.
        def stack_labels(drawings)
          seen = Hash.new(0)
          drawings.map do |edge, (d, label)|
            x, y, anchor = label
            next [edge, [d, label]] unless x && y

            at = [x.round, y.round]
            above = seen[at]
            seen[at] += 1
            [edge, [d, [x, y - above * (LABEL_H + 2), anchor]]]
          end
        end

        # [left, top, right, bottom] of everything drawn: the +root+ region's
        # boxes, and each drawing's line and label. A line's every point,
        # control points included, since a cubic stays within them; a label
        # by its width, from its anchor, and a line's height.
        def bounds(root, drawings)
          xs = [root.x, root.right]
          ys = [root.y, root.bottom]
          drawings.each do |edge, (d, (lx, ly, anchor))|
            d.scan(/-?\d+(?:\.\d+)?/).map(&:to_f).each_slice(2) do |x, y|
              xs << x
              ys << y if y
            end
            next unless lx && ly

            width = text_width(edge.label.to_s)
            left = case anchor
                   when 'middle' then lx - width / 2.0
                   when 'end' then lx - width
                   else lx
                   end
            xs.push(left, left + width)
            ys.push(ly - LABEL_H, ly + 4)
          end
          [xs.min, ys.min, xs.max, ys.max]
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
              draw_actions(s, box, box.y + PARALLEL_HEAD - 6)
              box.children.each { |region| draw_region(s, region) }
            in :compound
              s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 14, class: 'statechart__box')
              s.text(x: box.x + 14, y: box.y + 20, class: 'statechart__label') { state[:key] }
              s.text(x: box.right - 14, y: box.y + 20, class: 'statechart__hint', 'text-anchor': 'end') { compound_name(state) }
              draw_actions(s, box, box.y + PARALLEL_HEAD - 6)
              box.children.each { |region| draw_region_contents(s, region) }
            else
              s.rect(x: box.x, y: box.y, width: box.w, height: box.h, rx: 8, class: 'statechart__box')
              if box.kind == :final
                s.rect(x: box.x + 3, y: box.y + 3, width: box.w - 6, height: box.h - 6, rx: 6, class: 'statechart__final-ring')
              end
              badge = timer_badge(state)
              label_x = badge ? box.x + NODE_PAD : box.cx
              # Its name in the middle of its first NODE_H, its actions under a rule.
              name_y = box.y + NODE_H / 2.0 + 4
              s.text(x: label_x, y: name_y, class: 'statechart__label', 'text-anchor': badge ? 'start' : 'middle') { state[:key] }
              s.text(x: box.right - NODE_PAD, y: name_y, class: 'statechart__timer', 'text-anchor': 'end') { badge } if badge
              if action_lines(state).any?
                s.line(x1: box.x, y1: box.y + NODE_H, x2: box.right, y2: box.y + NODE_H, class: 'statechart__rule')
                draw_actions(s, box, box.y + NODE_H)
              end
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
                  to, label = resolve(state[:id], target, label)
                  edges << Edge.new(from: state[:id], to:, label:, kind: live ? :live : :command,
                                    starts: Array(transition[:starts]))
                end
              end
            end
            eventless(state).each do |label, target|
              to, label = resolve(state[:id], target, label)
              edges << Edge.new(from: state[:id], to:, label:, kind: :done)
            end
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
          @escalations.map do |from, target|
            to, label = resolve(from, target, 'on_final')
            Edge.new(from:, to:, label:, kind: :done)
          end
        end

        # Where an arrow from +from+ to +target+ is drawn, and its label: a
        # history node's goes to its checkpoint, marked (H) or (H*); a target
        # containing +from+ is re-entered (see #reentry).
        def resolve(from, target, label)
          to, label = @histories.key?(target) ? [@histories[target], "#{label} (#{history_mark(target)})"] : [target, label]
          [reentry(from, to), label]
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

        # Each edge's drawing, from its +legs+ ([placement, region, route]):
        # one laid out in pieces, through ports, is drawn as one line through
        # every piece, its label the labelled piece's.
        def stitched(legs)
          from_port = {} # Port => the leg leaving it
          after = {}     # Port => the leg leaving the checkpoint it's inside, there
          legs.each do |leg|
            p = leg[0]
            from_port[p.from] = leg if Port === p.from
            after[p.from_port] = leg if p.from_port
          end
          legs.filter_map do |leg|
            p, region, route = leg
            next if Port === p.from || p.from_port # carries on from another piece

            chain = [leg]
            while (q = chain.last[0])
              nxt = if Port === q.to then after[q.to]
                    elsif q.to_port then from_port[q.to_port]
                    end
              break unless nxt

              chain << nxt
            end
            next [p.edge, routed(region, p, route)] if chain.size == 1

            points = chain.flat_map { |_, r, rt| absolute(r, rt).first }
            labelled = chain.find { |pl, _, _| !pl.port_leg? }
            _, label = absolute(labelled[1], labelled[2])
            [p.edge, [path(points, nil), [*label, labelled[2].anchor]]]
          end
        end

        # A +route+ +region+ laid out, in the chart's coordinates: [points, label].
        def absolute(region, route)
          ox, oy = region.origin
          [route.points.map { |x, y| [ox + x, oy + y] }, route.label && [ox + route.label[0], oy + route.label[1]]]
        end

        # An edge its region laid out: the region's route, from and to the
        # children holding its ends, reaching on into them for ends nested deeper.
        def routed(region, placement, route)
          points, label = absolute(region, route)
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

        # A curve through every point, the way Pele (pele.run) draws its
        # layered edges: two points in line are joined by a straight run, and
        # any other two by one S that leaves and arrives upright, so a line
        # meets boxes square and never overshoots a bend. A point in between
        # that its line passes on the way across (it lies between the points
        # either side) is swept through, heading from the one before to the one
        # after, rather than stepped; so is one it turns back at (the lowest
        # point of a line under a rank). An S's handles reach half the way down
        # (#ease), and a sweep's a third of its stretch; neither past the
        # stretch's top or bottom, so it never doubles back up or down.
        def spline(points)
          points = points.chunk_while { |p, q| (p[0] - q[0]).abs < 0.01 && (p[1] - q[1]).abs < 0.01 }.map(&:first)
          return "M #{f points[0][0]} #{f points[0][1]}" if points.size < 2

          last = points.size - 1
          # nil: upright. Else the unit heading it sweeps through on.
          sweeps = points.each_index.map do |i|
            next nil if i.zero? || i == last

            (px, py), (x, y), (nx, ny) = points[i - 1], points[i], points[i + 1]
            across = (x - px) * (nx - x) > 0.01
            turns = (y - py) * (ny - y) < -0.01
            next nil unless across || turns

            length = Math.hypot(nx - px, ny - py)
            [(nx - px) / length, (ny - py) / length]
          end
          d = +"M #{f points[0][0]} #{f points[0][1]}"
          points.each_cons(2).with_index do |((x1, y1), (x2, y2)), i|
            if (x1 - x2).abs < 0.5 && !sweeps[i] && !sweeps[i + 1]
              # Straight on: a point part way along a run adds nothing.
              d << " L #{f x2} #{f y2}" unless i + 1 < last && !sweeps[i + 1] && (points[i + 2][0] - x2).abs < 0.5
              next
            end
            dy = y2 - y1
            s_reach = dy.abs * ease(x2 - x1, dy)
            reach = Math.hypot(x2 - x1, dy) / 3
            c1 = sweeps[i] ? [x1 + sweeps[i][0] * reach, y1 + sweeps[i][1] * reach] : [x1, y1 + (dy <=> 0) * s_reach]
            c2 = sweeps[i + 1] ? [x2 - sweeps[i + 1][0] * reach, y2 - sweeps[i + 1][1] * reach] : [x2, y2 - (dy <=> 0) * s_reach]
            low, high = [y1, y2].minmax
            d << " C #{f c1[0]} #{f c1[1].clamp(low, high)}, #{f c2[0]} #{f c2[1].clamp(low, high)}, #{f x2} #{f y2}"
          end
          d
        end

        # How far down an S's handles reach, as a share of how far it drops:
        # half, for an even S, but less for one that runs far across, down to a
        # quarter at sixteen times as far, so it crosses in a straighter line
        # (Pele's +ease+).
        def ease(across, along) = (4.0 * along.abs / [across.abs, 1].max).clamp(0.25, 0.5)

        # A +drawing+ is [path, [label x, label y, anchor]]. Its line and label
        # are drawn apart, each in a group with the edge's attributes.
        def draw_line(s, edge, (d, _))
          s.g(**edge_attributes(edge)) do
            s.path(d:, 'marker-end': "url(#sc-#{live?(edge) ? 'arrow-live' : 'arrow'})")
          end
        end

        def draw_label(s, edge, (_, (x, y, anchor)))
          s.g(**edge_attributes(edge)) do
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

        # Its classes, and the ids of the states it leaves and reaches, as
        # +data-from+ and +data-to+: the state a line is drawn to, so one
        # re-entering a parallel checkpoint reaches the start of its region.
        def edge_attributes(edge)
          {
            class: ['statechart__edge', "statechart__edge--#{edge.kind}", ('is-live' if live?(edge))].compact.join(' '),
            data: { from: edge.from, to: edge.to }
          }
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

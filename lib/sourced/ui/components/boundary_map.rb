# frozen_string_literal: true

require 'sidereal'
require 'sourced/ui/layered_layout'
require 'sourced/ui/edge_path'
require 'sourced/ui/boundaries'

module Sourced
  module UI
    module Components
      # Draws Boundaries as a map of the reactors, in SVG: a box for each
      # reactor a message crosses into or out of, and an arrow for each
      # Boundaries::Link, the way the messages go, labelled with them. Commands
      # dispatched (and children started) are blue, events reacted to orange,
      # and events projected or evolved from, the quietest, green and dashed.
      #
      # Without +projections+, it leaves out what's only read: projection
      # links, and the reactors only they link (most read models), so the
      # reactors that drive each other stand out.
      #
      # Hovering a reactor dims every arrow but its own.
      class BoundaryMap < Sidereal::Components::BaseComponent
        BOX_W = 184
        BOX_H = 50
        MARGIN = 16
        CHAR_W = 6.3       # average glyph width of a box's name
        LABEL_CHAR_W = 5.9 # the same, for an arrow's label
        LINE_H = 13
        MAX_LINES = 3      # of an arrow's label: then the first two, and how many more

        KINDS = %i[command event projection].freeze

        # @param boundaries [Boundaries, Boundaries::Grouped]
        # @param href [#call, nil] a reactor's URL from its group_id, or nil for none
        # @param projections [Boolean] whether to draw what's only read
        # @param title [String] accessible name for the drawing
        # @param node_data [#call, nil] a reactor's (or a group's) box => more
        #   +data-+ attributes for it, such as a Datastar click handler
        def initialize(boundaries, href: nil, projections: true, title: 'Reactor boundaries', node_data: nil)
          @boundaries = boundaries
          @href = href
          @node_data = node_data
          @title = title
          # Marker ids of its own: a page draws the map twice, and url(#id)
          # finds the first, hidden with its map.
          @arrow = ['bm-arrow', ('ns' if Boundaries::Grouped === boundaries), (projections ? 'all' : 'driving')].compact.join('-')
          @links = boundaries.links.select { projections || it.kind != :projection }
          ids = @links.flat_map { [it.from, it.to] }.uniq
          @reactors = boundaries.reactors.select { ids.include?(it.group_id) }
          @short = short_names(@links.flat_map(&:crossings).map(&:name).uniq)
          @labels = @links.to_h { [it.id, label_lines(it)] }
          @layout = layout
          @paths = @links.to_h { [it.id, path_of(@layout.routes.fetch(it.id))] }
          @placed = place_labels
        end

        def empty? = @links.empty?

        def view_template
          return if empty?

          # Labels may reach past the boxes, beside a line on the edge.
          x1 = [0, *@placed.values.map { it[:x] }].min - MARGIN
          x2 = [@layout.width, *@placed.values.map { it[:x] + it[:w] }].max + MARGIN
          w = (x2 - x1).ceil
          h = (@layout.height + MARGIN * 2).ceil
          svg(
            class: 'boundary-map',
            viewBox: "#{f x1} #{-MARGIN} #{w} #{h}",
            width: w,
            height: h,
            style: "--bm-w: #{w}px",
            role: 'img',
            aria: { label: @title }
          ) do |s|
            s.title { @title }
            s.style { highlight_rules }
            s.defs do
              KINDS.each do |kind|
                s.marker(id: "#{@arrow}-#{kind}", viewBox: '0 0 10 10', refX: 9, refY: 5,
                         markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse') do
                  s.path(d: 'M 0 1 L 9 5 L 0 9 z', class: "boundary-map__arrow boundary-map__arrow--#{kind}")
                end
              end
            end

            # Lines under the boxes, labels over both.
            @links.each { draw_line(s, it) }
            @reactors.each { draw_reactor(s, it) }
            @links.each { draw_label(s, it) }
          end
        end

        private

        def layout
          nodes = @reactors.map { LayeredLayout::Node.new(id: it.group_id, w: BOX_W, h: BOX_H, extra: 0, round: false) }
          edges = @links.map do |link|
            # No width for labels: they're placed once the lines are drawn
            # (#place_labels), so lines run as directly as they would bare.
            # Their height, so the gaps have room for them.
            lines = @labels.fetch(link.id).size
            LayeredLayout::Edge.new(id: link.id, from: link.from, to: link.to, label_w: lines.zero? ? 0 : SLOT_W,
                                    label_h: (lines * LINE_H * GAP_ROOM).ceil)
          end
          LayeredLayout.new(nodes, edges, starts:)
        end

        # Every reactor nothing crosses into, then one of each group of
        # reactors those don't reach (a cycle: a saga and the decider it
        # drives, each the other's start), so each group is ranked from its
        # own top, rather than all of it dropped in one last row.
        def starts
          ids = @reactors.map(&:group_id)
          out = Hash.new { |h, k| h[k] = [] }
          @links.each { out[it.from] << it.to }
          into = @links.map(&:to).to_set
          starts = ids.reject { into.include?(it) }
          reached = Set.new
          visit = lambda do |id|
            stack = [id]
            while (at = stack.pop)
              next unless reached.add?(at)

              stack.concat(out[at])
            end
          end
          starts.each(&visit)
          ids.each do |id|
            next if reached.include?(id)

            starts << id
            visit.(id)
          end
          starts
        end

        def draw_reactor(s, reactor)
          box = @layout.boxes.fetch(reactor.group_id)
          kind = kind_of(reactor)
          url = @href&.call(reactor.group_id)
          group = lambda do
            data = { node: reactor.group_id }.merge(@node_data&.call(reactor) || {})
            s.g(class: "boundary-map__node boundary-map__node--#{kind}", data:) do
              s.title { tooltip(reactor) }
              s.rect(x: box.x, y: box.y, width: BOX_W, height: BOX_H, rx: 6, class: 'boundary-map__box')
              s.rect(x: box.x, y: box.y + 6, width: 3, height: BOX_H - 12, rx: 1.5, class: 'boundary-map__stripe')
              s.text(x: box.x + 14, y: box.y + 19, class: 'boundary-map__kind') do
                kind_line(reactor, kind)
              end
              s.text(x: box.x + 14, y: box.y + 36, class: 'boundary-map__name') do
                truncate(reactor.label, BOX_W - 24, CHAR_W)
              end
            end
          end
          url ? s.a(href: url, class: 'boundary-map__link') { group.call } : group.call
        end

        def kind_line(reactor, kind)
          if Boundaries::Group === reactor
            count = reactor.members.size
            return "#{count} reactor#{'s' unless count == 1} · #{reactor.inside} inside"
          end

          entries = reactor.entries.size
          entries.zero? ? kind.to_s : "#{kind} · #{entries} from outside"
        end

        def tooltip(reactor)
          if Boundaries::Group === reactor
            return [reactor.label, *reactor.members.map { "  #{it.label}" },
                    "#{reactor.inside} crossings between them"].join("\n")
          end

          lines = [reactor.reactor&.name || reactor.group_id]
          lines << "Commands from outside: #{reactor.entries.join(', ')}" if reactor.entries.any?
          lines.join("\n")
        end

        def path_of(route) = route.flat == :straight ? straight(route.points) : EdgePath.spline(route.points)

        def draw_line(s, link)
          d = @paths.fetch(link.id)
          s.path(d:, class: "boundary-map__edge boundary-map__edge--#{link.kind}", data: { ends: "#{link.from} #{link.to}" },
                 'marker-end': "url(##{@arrow}-#{link.kind})") do
            s.title { messages_title(link) }
          end
        end

        def messages_title(link) = link.crossings.map { "#{it.name} (#{it.relation})" }.join("\n")

        def straight(((x1, y1), (x2, y2))) = "M #{f x1} #{f y1} L #{f x2} #{f y2}"

        def draw_label(s, link)
          spot = @placed[link.id] or return

          lines = @labels.fetch(link.id)
          x = spot[:anchor] == 'end' ? spot[:x] + spot[:w] : spot[:x]
          s.text(class: "boundary-map__label boundary-map__label--#{link.kind}", 'text-anchor': spot[:anchor],
                 data: { ends: "#{link.from} #{link.to}" }) do
            s.title { messages_title(link) }
            lines.each_with_index do |line, i|
              s.tspan(x: f(x), y: f(spot[:y] + LINE_H - 3 + i * LINE_H)) { line }
            end
          end
        end

        LABEL_GAP = 5   # between a line and its label
        SLOT_W = 28     # room beside a labelled line, so labelled lines spread a little
        GAP_ROOM = 2.5  # gaps this many labels tall, so labels can stagger down them
        CLEARANCE = 3   # around labels and boxes, kept free of other labels
        SLIDES = [0, 16, 32].freeze # how far out from its line a label may go, when there's no room by it

        # Each label beside its own line, where it overlaps no box and no other
        # label: the spot nearest the middle of the line's run down between
        # its boxes, on its right if there's room, else its left; failing
        # those, a little further out (SLIDES). The most lines first, they're
        # hardest to fit. A label with no free spot goes where it covers least.
        #
        # @return [Hash{String => Hash}] link id => {x:, y:, w:, h:, anchor:}, its box's top left
        def place_labels
          taken = @layout.boxes.values.map { [it.x, it.y, it.x + BOX_W, it.y + BOX_H] }
          labelled = @links.select { @labels.fetch(it.id).any? }
          labelled.sort_by { -@labels.fetch(it.id).size }.to_h do |link|
            lines = @labels.fetch(link.id)
            w = lines.map(&:length).max * LABEL_CHAR_W
            h = lines.size * LINE_H
            points = candidates(@paths.fetch(link.id))
            # Right beside the line first; then further out, still on its side.
            spots = SLIDES.flat_map do |out|
              points.flat_map do |px, py|
                [[px + LABEL_GAP + out, py - h / 2.0, 'start'], [px - LABEL_GAP - out - w, py - h / 2.0, 'end']]
              end
            end
            free = spots.find { |x, y, _| taken.none? { overlap?(it, [x, y, x + w, y + h]) } }
            # None free: where it covers least of what's there.
            free ||= spots.min_by { |x, y, _| taken.sum { overlap_area(it, [x, y, x + w, y + h]) } }
            x, y, anchor = free || [0, 0, 'start']
            taken << [x, y, x + w, y + h]
            [link.id, { x:, y:, w:, h:, anchor: }]
          end
        end

        # Points along a path's run between its boxes, the middle first, then
        # out towards its ends.
        def candidates(d)
          points = sample(d)
          return points if points.size < 3

          # Labels keep off the boxes themselves (#place_labels), so any point
          # down the run will do.
          ys = points.map(&:last)
          middle = (ys.min + ys.max) / 2.0
          points.sort_by { (it[1] - middle).abs }
        end

        STEP = 1.5 # pixels between the points tried along a line

        # Points every STEP pixels or so along an SVG path of M, L and C commands.
        def sample(d)
          points = []
          at = nil
          d.scan(/([MLC])([^MLC]*)/).each do |cmd, args|
            nums = args.scan(/-?\d+(?:\.\d+)?/).map(&:to_f).each_slice(2).to_a
            case cmd
            in 'M' then at = nums.first
            in 'L'
              nums.each do |to|
                n = [(Math.hypot(to[0] - at[0], to[1] - at[1]) / STEP).ceil, 1].max
                points.concat((1..n).map { |i| t = i.fdiv(n); [at[0] + (to[0] - at[0]) * t, at[1] + (to[1] - at[1]) * t] })
                at = to
              end
            in 'C'
              nums.each_slice(3) do |c1, c2, to|
                # The control polygon is at least as long as the curve.
                n = [[at, c1, c2, to].each_cons(2).sum { |p, q| Math.hypot(q[0] - p[0], q[1] - p[1]) }.fdiv(STEP).ceil, 1].max
                points.concat((1..n).map { |i| bezier(at, c1, c2, to, i.fdiv(n)) })
                at = to
              end
            end
          end
          points
        end

        def bezier(p0, p1, p2, p3, t)
          u = 1 - t
          [0, 1].map { |k| u**3 * p0[k] + 3 * u**2 * t * p1[k] + 3 * u * t**2 * p2[k] + t**3 * p3[k] }
        end

        def overlap_area((ax1, ay1, ax2, ay2), (bx1, by1, bx2, by2))
          [[ax2, bx2].min - [ax1, bx1].max + CLEARANCE, 0].max * [[ay2, by2].min - [ay1, by1].max + CLEARANCE, 0].max
        end

        def overlap?((ax1, ay1, ax2, ay2), (bx1, by1, bx2, by2))
          ax1 < bx2 + CLEARANCE && bx1 < ax2 + CLEARANCE && ay1 < by2 + CLEARANCE && by1 < ay2 + CLEARANCE
        end

        # A line for each message, at most MAX_LINES: past that, the first
        # two and how many more. Reads go unlabelled: there are many, and a
        # label slot each crowds the gaps they cross, pushing other lines'
        # labels, and so their lines, aside. Their messages are in the
        # line's tooltip, and the table.
        def label_lines(link)
          return [] if link.kind == :projection

          names = link.crossings.map { @short.fetch(it.name) }.uniq

          names = names.first(MAX_LINES - 1) + ["+#{names.size - MAX_LINES + 1} more"] if names.size > MAX_LINES
          names
        end

        # Each message's class name, as short as it can be without two of them
        # reading the same: Parcel::Started next to Trip::Started, just
        # OrderPlaced when it's the only one.
        def short_names(names)
          names.to_h do |name|
            parts = name.split('::')
            others = (names - [name]).map { it.split('::') }
            size = (1..parts.size).find { |n| others.none? { it.last(n) == parts.last(n) } } || parts.size
            [name, parts.last(size).join('::')]
          end
        end

        # Two rules per reactor: hovering it dims every line and label but its
        # own, and so does picking it (its box lit, .is-selected, as the full
        # screen map does), while no box is hovered.
        def highlight_rules
          rules = @reactors.flat_map do |reactor|
            id = reactor.group_id.gsub(/["\\]/) { "\\#{it}" }
            others = "[data-ends]:not([data-ends~=\"#{id}\"]) { opacity: 0.12; }"
            [
              ".boundary-map:has([data-node=\"#{id}\"]:hover) #{others}",
              ".boundary-map:not(:has([data-node]:hover)):has([data-node=\"#{id}\"].is-selected) #{others}"
            ]
          end
          raw safe(rules.join("\n"))
        end

        def kind_of(reactor)
          return 'namespace' if Boundaries::Group === reactor

          klass = reactor.reactor
          return 'reactor' unless Module === klass

          Boundaries::KINDS.find { |base, _| klass <= base }&.last || 'reactor'
        end

        def truncate(text, width, char_w)
          max = (width / char_w).floor
          text.length > max ? "#{text[0, max - 1]}…" : text
        end

        def f(n) = n.round(1)
      end
    end
  end
end

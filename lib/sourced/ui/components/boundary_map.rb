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

        # @param boundaries [Boundaries]
        # @param href [#call, nil] a reactor's URL from its group_id, or nil for none
        # @param projections [Boolean] whether to draw what's only read
        # @param title [String] accessible name for the drawing
        def initialize(boundaries, href: nil, projections: true, title: 'Reactor boundaries')
          @boundaries = boundaries
          @href = href
          @title = title
          # Marker ids of its own: a page draws the map twice, and url(#id)
          # finds the first, hidden with its map.
          @arrow = projections ? 'bm-arrow' : 'bm-arrow-driving'
          @links = boundaries.links.select { projections || it.kind != :projection }
          ids = @links.flat_map { [it.from, it.to] }.uniq
          @reactors = boundaries.reactors.select { ids.include?(it.group_id) }
          @short = short_names(@links.flat_map(&:crossings).map(&:name).uniq)
          @labels = @links.to_h { [it.id, label_lines(it)] }
          @layout = layout
        end

        def empty? = @links.empty?

        def view_template
          return if empty?

          w = (@layout.width + MARGIN * 2).ceil
          h = (@layout.height + MARGIN * 2).ceil
          svg(
            class: 'boundary-map',
            viewBox: "#{-MARGIN} #{-MARGIN} #{w} #{h}",
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
            lines = @labels.fetch(link.id)
            LayeredLayout::Edge.new(id: link.id, from: link.from, to: link.to,
                                    label_w: (lines.map(&:length).max * LABEL_CHAR_W).ceil, label_h: lines.size * LINE_H)
          end
          LayeredLayout.new(nodes, edges, starts: starts)
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
            s.g(class: "boundary-map__node boundary-map__node--#{kind}", data: { node: reactor.group_id }) do
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
          entries = reactor.entries.size
          entries.zero? ? kind.to_s : "#{kind} · #{entries} from outside"
        end

        def tooltip(reactor)
          lines = [reactor.reactor&.name || reactor.group_id]
          lines << "Commands from outside: #{reactor.entries.join(', ')}" if reactor.entries.any?
          lines.join("\n")
        end

        def draw_line(s, link)
          route = @layout.routes.fetch(link.id)
          d = route.flat == :straight ? straight(route.points) : EdgePath.spline(route.points)
          s.path(d:, class: "boundary-map__edge boundary-map__edge--#{link.kind}", data: { ends: "#{link.from} #{link.to}" },
                 'marker-end': "url(##{@arrow}-#{link.kind})")
        end

        def straight(((x1, y1), (x2, y2))) = "M #{f x1} #{f y1} L #{f x2} #{f y2}"

        # Lines stacked from the route's label point: down from it, but up
        # from it above a straight arrow, so the last line stays clear of it.
        def draw_label(s, link)
          route = @layout.routes.fetch(link.id)
          return unless route.label

          lines = @labels.fetch(link.id)
          x, y = route.label
          top = case route.flat
                in :straight then y - (lines.size - 1) * LINE_H
                in :under then y - lines.size * LINE_H + LINE_H - 2
                else y - (lines.size - 1) * LINE_H / 2.0
                end
          s.text(class: "boundary-map__label boundary-map__label--#{link.kind}", 'text-anchor': route.anchor,
                 data: { ends: "#{link.from} #{link.to}" }) do
            s.title { link.crossings.map { "#{it.name} (#{it.relation})" }.join("\n") }
            lines.each_with_index do |line, i|
              s.tspan(x: f(x), y: f(top + i * LINE_H)) { line }
            end
          end
        end

        # A line for each message, at most MAX_LINES: past that, the first
        # two and how many more. A projection's, one line.
        def label_lines(link)
          names = link.crossings.map { @short.fetch(it.name) }.uniq
          # Reads are many, and say least: just how many.
          return [names.size == 1 ? names.first : "#{names.size} events"] if link.kind == :projection

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

        # One rule per reactor: hovering it dims every line and label but its own.
        def highlight_rules
          rules = @reactors.map do |reactor|
            id = reactor.group_id.gsub(/["\\]/) { "\\#{it}" }
            ".boundary-map:has([data-node=\"#{id}\"]:hover) [data-ends]:not([data-ends~=\"#{id}\"]) { opacity: 0.12; }"
          end
          raw safe(rules.join("\n"))
        end

        def kind_of(reactor)
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

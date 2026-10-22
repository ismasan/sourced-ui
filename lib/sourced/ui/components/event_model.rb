# frozen_string_literal: true

require 'sidereal'

module Sourced
  module UI
    module Components
      # Draws an EventFlow as an event model, in SVG: a timeline, one step per
      # column, in lanes for automations, commands and read models, and each
      # reactor's events. Commands are blue, events orange, read models green,
      # and automations (reactions) carry a robot.
      #
      # With +schemas+, boxes are wider and list their message's payload
      # fields under the name, and each lane is as tall as its tallest box.
      class EventModel < Sidereal::Components::BaseComponent
        LABEL_W = 136      # the lanes' names, on the left
        GAP_X = 40         # between columns, for the arrows
        BOX_W = 128
        SCHEMA_BOX_W = 184
        BOX_H = 64         # a box's head: kind, name, reactor
        LANE_PAD = 14      # above and below the tallest box in a lane
        PAD = 16
        CHAR_W = 6.4       # average glyph width of a box's name
        FIELD_CHAR_W = 5.8 # the same, for fields
        LINE_H = 13
        FIELD_H = 13
        MAX_FIELDS = 10

        KIND_LABELS = { command: 'Command', event: 'Event', readmodel: 'Read model', automation: 'Automation' }.freeze

        # @param flow [EventFlow]
        # @param href [#call, nil] a node's reactor's URL from its group_id, or nil for none
        # @param title [String] accessible name for the drawing
        # @param schemas [Boolean] whether boxes list their messages' payload fields
        def initialize(flow, href: nil, title: "#{flow.group_id} event model", schemas: false)
          @flow = flow
          @href = href
          @title = title
          @schemas = schemas
          @box_w = schemas ? SCHEMA_BOX_W : BOX_W
          @col_w = @box_w + GAP_X
          @nodes = flow.nodes.to_h { [it.id, it] }
          @lane_h = flow.lanes.to_h do |lane|
            tallest = flow.nodes.select { it.lane == lane.id }.map { box_h(it) }.max || BOX_H
            [lane.id, tallest + LANE_PAD * 2]
          end
          top = 0
          @lane_y = flow.lanes.to_h { |lane| [lane.id, top].tap { top += @lane_h.fetch(lane.id) } }
        end

        # Whether any message in +flow+ has payload fields to list.
        def self.schemas?(flow) = flow.nodes.any? { fields_of(it.schema).any? }

        # [name, type, required] for each payload field in a JSON schema.
        def self.fields_of(schema)
          required = Array(schema['required'])
          (schema['properties'] || {}).map { |name, prop| [name, type_label(prop), required.include?(name)] }
        end

        # A field's type, short: its format (uuid, date) or type, an enum's
        # values, an array's item type in brackets, alternatives with |.
        def self.type_label(prop)
          variants = prop['anyOf'] || prop['oneOf']
          return variants.map { type_label(it) }.uniq.then { |l| l.size > 1 ? (l - ['string']) : l }.join('|') if variants
          return prop['enum'].map(&:to_s).join('|') if prop['enum']
          return "[#{type_label(prop['items'] || {})}]" if prop['type'] == 'array'

          (prop['format'] || Array(prop['type']).join('|')).then { it.empty? ? 'any' : it }
        end

        def view_template
          width = LABEL_W + PAD * 2 + @flow.columns * @col_w - GAP_X
          height = @lane_h.values.sum

          # No viewBox: drawn at 1:1, as wide as its container or the flow,
          # whichever is wider, its lanes running the full width.
          svg(
            class: 'event-model',
            width: '100%',
            height:,
            style: "--em-w: #{width}px",
            role: 'img',
            aria: { label: @title }
          ) do |s|
            s.title { @title }
            s.defs do
              s.marker(id: arrow_id, viewBox: '0 0 10 10', refX: 9, refY: 5,
                       markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse') do
                s.path(d: 'M 0 1 L 9 5 L 0 9 z', class: 'event-model__arrow')
              end
            end

            @flow.lanes.each { draw_lane(s, it) }
            @flow.edges.each { draw_edge(s, it) }
            @flow.nodes.each { draw_node(s, it) }
          end
        end

        private

        def draw_lane(s, lane)
          y = @lane_y.fetch(lane.id)
          h = @lane_h.fetch(lane.id)
          s.g(class: "event-model__lane event-model__lane--#{lane.kind}") do
            s.rect(x: 0, y:, width: '100%', height: h, class: 'event-model__lane-bg')
            s.line(x1: 0, y1: y + h, x2: '100%', y2: y + h, class: 'event-model__lane-rule')
            # Level with the boxes' heads, however tall the lane.
            label_y = y + LANE_PAD + BOX_H / 2.0
            case lane.kind
            in :automation
              robot(s, PAD, label_y - 12)
              s.text(x: PAD + 20, y: label_y - 2, class: 'event-model__lane-name') { lane.label }
            in :interaction
              s.text(x: PAD, y: label_y - 4, class: 'event-model__lane-name') { 'Commands' }
              s.text(x: PAD, y: label_y + 10, class: 'event-model__lane-name') { 'Read models' }
            in :event
              s.text(x: PAD, y: label_y - 4, class: 'event-model__lane-kind') { 'Events' }
              short_lines(lane.label, LABEL_W - PAD * 2, 2).each_with_index do |line, i|
                s.text(x: PAD, y: label_y + 10 + i * LINE_H, class: 'event-model__lane-name') { line }
              end
            end
          end
        end

        def draw_node(s, node)
          x, y = position(node)
          classes = ['event-model__node', "event-model__node--#{node.kind}"]
          classes << 'is-external' unless node.own
          href = !node.own && @href&.call(node.group_id)

          group = proc do
            s.g(class: classes.join(' ')) do
              s.title { tooltip(node) }
              s.rect(x:, y:, width: @box_w, height: box_h(node), rx: 4, class: 'event-model__box')
              if node.kind == :automation
                robot(s, x + 8, y + 7)
                s.text(x: x + 26, y: y + 18, class: 'event-model__kind') { 'reaction' }
              else
                s.text(x: x + 8, y: y + 16, class: 'event-model__kind') { KIND_LABELS.fetch(node.kind).downcase }
              end
              lines = short_lines(display_name(node), @box_w - 16, 2)
              lines.each_with_index do |line, i|
                s.text(x: x + 8, y: y + 33 + i * LINE_H, class: 'event-model__name') { line }
              end
              if caption?(node)
                s.text(x: x + 8, y: y + head_h(node) - 7, class: 'event-model__group') { truncate(node.group_id, @box_w - 16, 10 / 11.5) }
              end
              draw_fields(s, node, x, y) if @schemas
            end
          end

          href ? s.a(href:, class: 'event-model__link', &group) : group.call
        end

        # The payload's fields under the box's head: name on the left, type on
        # the right, optional ones marked ?.
        def draw_fields(s, node, x, y)
          fields = self.class.fields_of(node.schema)
          return if fields.empty?

          top = y + head_h(node)
          s.line(x1: x + 8, y1: top, x2: x + @box_w - 8, y2: top, class: 'event-model__rule')
          shown = fields.first(fields.size > MAX_FIELDS ? MAX_FIELDS - 1 : MAX_FIELDS)
          name_w = (@box_w - 16) * 0.55
          shown.each_with_index do |(name, type, required), i|
            row_y = top + 15 + i * FIELD_H
            label = required ? name : "#{name}?"
            s.text(x: x + 8, y: row_y, class: 'event-model__field') { truncate(label, name_w, FIELD_CHAR_W / CHAR_W) }
            s.text(x: x + @box_w - 8, y: row_y, class: 'event-model__type', 'text-anchor': 'end') do
              truncate(type, @box_w - 16 - name_w - 6, FIELD_CHAR_W / CHAR_W)
            end
          end
          return unless fields.size > shown.size

          s.text(x: x + 8, y: top + 15 + shown.size * FIELD_H, class: 'event-model__type') { "+#{fields.size - shown.size} more" }
        end

        # Each drawing's own, so a page can hold both (one hidden): a marker in a
        # hidden SVG draws nothing where it's used.
        def arrow_id = @schemas ? 'em-arrow-schemas' : 'em-arrow'

        # The box's full name and type, and with schemas its fields uncut.
        def tooltip(node)
          text = "#{KIND_LABELS.fetch(node.kind)}: #{node.name}\n#{node.id}\nfrom #{node.group_id}"
          return text unless @schemas

          fields = self.class.fields_of(node.schema).map { |name, type, required| "\n  #{name}#{'?' unless required}: #{type}" }
          fields.any? ? "#{text}\n#{fields.join}" : text
        end

        # Other reactors' steps name their reactor, unless the name says it.
        def caption?(node)
          !node.own && node.kind != :event && display_name(node) != node.group_id.split('::').last
        end

        # A box's head: the same for every box, or with schemas only as tall as
        # its name and caption, so its fields follow straight on.
        def head_h(node)
          return BOX_H unless @schemas

          lines = short_lines(display_name(node), @box_w - 16, 2).size
          22 + lines * LINE_H + (caption?(node) ? 14 : 0) + 6
        end

        # A box's height: its head, and with schemas its fields.
        def box_h(node)
          return BOX_H unless @schemas

          rows = [self.class.fields_of(node.schema).size, MAX_FIELDS].min
          rows.zero? ? [head_h(node), 44].max : head_h(node) + 6 + rows * FIELD_H + 2
        end

        def draw_edge(s, edge)
          from = @nodes.fetch(edge.from)
          to = @nodes.fetch(edge.to)
          fx, fy = position(from)
          tx, ty = position(to)

          # Arrows meet boxes level with their heads, however tall the boxes.
          path = if to.column > from.column
                   x1 = fx + @box_w
                   y1 = fy + BOX_H / 2.0
                   x2 = tx
                   y2 = ty + BOX_H / 2.0
                   dx = [(x2 - x1) / 2.0, 24].max
                   "M #{x1} #{y1} C #{x1 + dx} #{y1}, #{x2 - dx} #{y2}, #{x2} #{y2}"
                 else
                   # Back in time (a cycle): under both boxes.
                   x1 = fx + @box_w / 2.0
                   x2 = tx + @box_w / 2.0
                   y1 = fy + box_h(from)
                   y2 = ty + box_h(to)
                   low = [y1, y2].max + LANE_PAD - 2
                   "M #{x1} #{y1} C #{x1} #{low}, #{x2} #{low}, #{x2} #{y2}"
                 end
          s.path(d: path, class: 'event-model__edge', 'marker-end': "url(##{arrow_id})")
        end

        def position(node)
          [LABEL_W + PAD + node.column * @col_w, @lane_y.fetch(node.lane) + LANE_PAD]
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

        # Class names lose their namespaces, and a reaction reads as what it's
        # on: reaction(HolidayBooking::BookingConfirmed) is on BookingConfirmed.
        def display_name(node)
          name = node.kind == :readmodel ? node.name.split('::').last : node.name.gsub(/(?:\w+::)+(\w+)/, '\1')
          name.sub(/\Areaction\((.+)\)\z/, 'on \1')
        end

        # +text+ in up to +max+ lines of +width+, broken at spaces, and at camel
        # case boundaries within a word too long for a line; the last line cut
        # short with an ellipsis.
        def short_lines(text, width, max)
          per_line = (width / CHAR_W).floor
          # Words keep the space after them, so pieces join back as they were.
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

        def truncate(text, width, scale)
          per_line = (width / (CHAR_W * scale)).floor
          text.length > per_line ? "#{text[0, per_line - 1]}…" : text
        end
      end
    end
  end
end

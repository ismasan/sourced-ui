# frozen_string_literal: true

require 'sidereal'

module Sourced
  module UI
    module Components
      # Draws an EventFlow as an event model, in SVG: a timeline, one step per
      # column, in lanes for automations, commands and read models, and each
      # reactor's events. Commands are blue, events orange, read models green,
      # and automations (reactions) carry a robot.
      class EventModel < Sidereal::Components::BaseComponent
        LABEL_W = 136      # the lanes' names, on the left
        COL_W = 168
        BOX_W = 128
        BOX_H = 64
        LANE_H = 92
        PAD = 16
        CHAR_W = 6.4       # average glyph width of a box's name
        LINE_H = 13

        KIND_LABELS = { command: 'Command', event: 'Event', readmodel: 'Read model', automation: 'Automation' }.freeze

        # @param flow [EventFlow]
        # @param href [#call, nil] a node's reactor's URL from its group_id, or nil for none
        # @param title [String] accessible name for the drawing
        def initialize(flow, href: nil, title: "#{flow.group_id} event model")
          @flow = flow
          @href = href
          @title = title
          @lane_index = flow.lanes.each_with_index.to_h { |lane, i| [lane.id, i] }
          @nodes = flow.nodes.to_h { [it.id, it] }
        end

        def view_template
          width = LABEL_W + PAD * 2 + @flow.columns * COL_W - (COL_W - BOX_W)
          height = @flow.lanes.size * LANE_H

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
              s.marker(id: 'em-arrow', viewBox: '0 0 10 10', refX: 9, refY: 5,
                       markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse') do
                s.path(d: 'M 0 1 L 9 5 L 0 9 z', class: 'event-model__arrow')
              end
            end

            @flow.lanes.each_with_index { |lane, i| draw_lane(s, lane, i) }
            @flow.edges.each { draw_edge(s, it) }
            @flow.nodes.each { draw_node(s, it) }
          end
        end

        private

        def draw_lane(s, lane, index)
          y = index * LANE_H
          s.g(class: "event-model__lane event-model__lane--#{lane.kind}") do
            s.rect(x: 0, y:, width: '100%', height: LANE_H, class: 'event-model__lane-bg')
            s.line(x1: 0, y1: y + LANE_H, x2: '100%', y2: y + LANE_H, class: 'event-model__lane-rule')
            label_y = y + LANE_H / 2.0
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
              s.title { "#{KIND_LABELS.fetch(node.kind)}: #{node.name}\n#{node.id}\nfrom #{node.group_id}" }
              s.rect(x:, y:, width: BOX_W, height: BOX_H, rx: 4, class: 'event-model__box')
              if node.kind == :automation
                robot(s, x + 8, y + 7)
                s.text(x: x + 26, y: y + 18, class: 'event-model__kind') { 'reaction' }
              else
                s.text(x: x + 8, y: y + 16, class: 'event-model__kind') { KIND_LABELS.fetch(node.kind).downcase }
              end
              lines = short_lines(display_name(node), BOX_W - 16, 2)
              lines.each_with_index do |line, i|
                s.text(x: x + 8, y: y + 33 + i * LINE_H, class: 'event-model__name') { line }
              end
              if !node.own && node.kind != :event && display_name(node) != node.group_id.split('::').last
                s.text(x: x + 8, y: y + BOX_H - 7, class: 'event-model__group') { truncate(node.group_id, BOX_W - 16, 10 / 11.5) }
              end
            end
          end

          href ? s.a(href:, class: 'event-model__link', &group) : group.call
        end

        def draw_edge(s, edge)
          from = @nodes.fetch(edge.from)
          to = @nodes.fetch(edge.to)
          fx, fy = position(from)
          tx, ty = position(to)

          path = if to.column > from.column
                   x1 = fx + BOX_W
                   y1 = fy + BOX_H / 2.0
                   x2 = tx
                   y2 = ty + BOX_H / 2.0
                   dx = [(x2 - x1) / 2.0, 24].max
                   "M #{x1} #{y1} C #{x1 + dx} #{y1}, #{x2 - dx} #{y2}, #{x2} #{y2}"
                 else
                   # Back in time (a cycle): under both boxes.
                   x1 = fx + BOX_W / 2.0
                   x2 = tx + BOX_W / 2.0
                   y1 = fy + BOX_H
                   y2 = ty + BOX_H
                   low = [y1, y2].max + (LANE_H - BOX_H) / 2.0 - 2
                   "M #{x1} #{y1} C #{x1} #{low}, #{x2} #{low}, #{x2} #{y2}"
                 end
          s.path(d: path, class: 'event-model__edge', 'marker-end': 'url(#em-arrow)')
        end

        def position(node)
          [LABEL_W + PAD + node.column * COL_W, @lane_index.fetch(node.lane) * LANE_H + (LANE_H - BOX_H) / 2.0]
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

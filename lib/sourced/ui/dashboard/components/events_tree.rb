# frozen_string_literal: true

require 'sourced/ui/dashboard/components/component'

module Sourced
  module UI
    module Dashboard
      module Components
        class EventsTree < Component
          Node = Struct.new(:parent, :children)

          def initialize(events: [], highlighted: nil)
            @events = build_tree(events)
            @current_event = highlighted ? events.find { |e| e.id == highlighted } : nil
          end

          private def build_tree(events)
            # Create a lookup hash for quick access to events by ID
            node_map = events.each_with_object({}) { |event, map| map[event.id] = Node.new(event, []) }

            # Track root events (those without parents)
            root_nodes = []

            # Build parent-child relationships
            node_map.values.each do |node|
              if node.parent.causation_id == node.parent.id
                # This is a root event
                root_nodes << node
              else
                # Find parent and add this event as its child
                parent = node_map[node.parent.causation_id]
                parent.children << node if parent
              end
            end

            root_nodes
          end

          def view_template
            div(id: 'events-tree', class: 'events-timeline') do
              if @current_event
                h4 { 'Current event' }
                div(class: 'current-event') do
                  dl(class: 'event-meta prop-table') do
                    dt { 'event ID'}
                    dd { @current_event.id.to_s }
                    dt { 'created at'}
                    dd { @current_event.created_at.to_s }
                    dt { 'correlation ID'}
                    dd { @current_event.correlation_id }
                    dt { 'causation ID'}
                    dd { @current_event.causation_id }
                    dt { 'sequence in stream'}
                    dd { @current_event.seq }
                    @current_event.metadata&.each do |key, value|
                      dt { key.to_s }
                      dd { value.to_s }
                    end
                  end
                end
              end
              h4 { 'Correlation view' }
              ul(class: 'tree tree-view') do
                @events.each do |node|
                  render_node(node)
                end
              end
            end
          end

          def render_node(node)
            li do
              event = node.parent
              MessageRow(
                event,
                href: nil,
                highlighted: @current_event&.id == event.id
              )

              if node.children.any?
                ul do
                  node.children.each do |child|
                    render_node(child)
                  end
                end
              end
            end
          end

          def producer_for(event)
            code { "[#{event.metadata[:producer]}] " } if event.metadata[:producer]
          end

          private def is_command?(event)
            event.id == event.causation_id
          end
        end
      end
    end
  end
end

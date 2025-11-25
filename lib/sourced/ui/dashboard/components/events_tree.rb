# frozen_string_literal: true

require 'sourced/ui/dashboard/components/component'

module Sourced
  module UI
    module Dashboard
      module Components
        class EventsTree < Component
          def initialize(events: [], event_id: nil)
            @events = Sourced::UI::Dashboard.build_causation_tree(events)
            @event_id = event_id
          end

          def view_template
            div(id: 'events-tree', class: 'events-timeline') do
              button(class: 'toggle-payloads', data: { 'on:click' => '$showPayloads = !$showPayloads'  }) do
                span(data: { text: '$showPayloads ? "Hide Payloads" : "Show Payloads"' })
              end
              ul(class: 'tree tree-view') do
                @events.each do |node|
                  render_node(node)
                end
              end
            end
          end

          def render_node(node)
            li do
              event = node.message
              MessageRow(
                event,
                href: nil,
                highlighted: @event_id == event.id
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

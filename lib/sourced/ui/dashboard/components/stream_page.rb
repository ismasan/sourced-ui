# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'
require 'sourced/ui/dashboard/components/event_list'

module Sourced
  module UI
    module Dashboard
      module Components
        class StreamPage < Component
          def initialize(stream_id:, events: [], event_id: nil, content: nil)
            @stream_id = stream_id
            @event_id = event_id
            @events = events
            @content = content
          end

          def view_template
            Layout(title: "stream: #{@stream_id}") do
              div id: 'container' do
                div id: 'main', data: _d.signals(showPayloads: false).to_h do
                  h1 { "stream: #{@stream_id}" }
                  if @content
                    render @content
                  end
                end

                div id: 'sidebar' do
                  EventList(events: @events, highlighted: @event_id)
                end
              end
            end
          end
        end
      end
    end
  end
end

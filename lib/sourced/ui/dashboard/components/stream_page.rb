# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'
require 'sourced/ui/dashboard/components/event_list'

module Sourced
  module UI
    module Dashboard
      module Components
        class StreamPage < Component
          def initialize(stream_id:, events: [], seq: nil, content: nil, layout: true)
            @stream_id = stream_id
            @events = events
            @current_event = if seq
              events.find { |e| e.seq == seq }
            else
              @events.last
            end
            @content = content
            @layout = layout
          end

          private def switch_layout(**kargs, &)
            if @layout
              Layout(**kargs) do
                div(id: 'container', &)
              end
            else
              div(id: 'container', &)
            end
          end

          def view_template
            switch_layout(title: "stream: #{@stream_id}") do
              div id: 'main', data: _d.signals(showPayloads: false).to_h do
                h1 { "stream: #{@stream_id}" }

                if @current_event
                  h4 { 'Current event' }
                  div(class: 'current-event') do
                    dl(class: 'event-meta prop-table') do
                      dt { 'event ID'}
                      dd { @current_event.id.to_s }
                      dt { 'type'}
                      dd { @current_event.type.to_s }
                      dt { 'created at'}
                      dd { @current_event.created_at.to_s }
                      dt { 'correlation ID'}
                      dd do
                        ref = _d.on.click.get(helpers.url("/events/#{@current_event.id}/correlation"))
                        a(href: '#', data: ref.to_h) { @current_event.correlation_id }
                      end
                      dt { 'causation ID'}
                      dd { @current_event.causation_id }
                      dt { 'sequence in stream'}
                      dd { @current_event.seq }
                      @current_event.metadata&.each do |key, value|
                        dt { key.to_s }
                        dd { value.to_s }
                      end
                    end
                    if @current_event.payload
                      div(class: 'event-payload') do
                        JSON.pretty_generate(@current_event.payload&.to_h || {})
                      end
                    end
                  end
                end
                if @content
                  render @content
                end
              end

              div id: 'sidebar' do
                EventList(events: @events, seq: @current_event&.seq)
              end
            end
          end
        end
      end

    end
  end
end

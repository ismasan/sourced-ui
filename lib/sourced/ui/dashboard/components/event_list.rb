# frozen_string_literal: true

require 'sourced/ui/dashboard/components/component'
require 'sourced/ui/dashboard/components/message_row'

module Sourced
  module UI
    module Dashboard
      module Components
        class EventList < Component
          def initialize(events:, highlighted: nil, reverse: true)
            @events = events
            @first_seq = @events.first&.seq
            @last_seq = @events.last&.seq
            @events = @events.reverse if reverse
            @highlighted = highlighted
          end

          def view_template
            div id: 'event-list' do
              div class: 'header' do
                h2 { 'History' }
                if @events.any?
                  div(class: 'history-tools') do
                    span(class: 'pagination') do
                      small { "current sequence number: #{@last_seq} " }
                    end

                    div(class: 'switches') do
                      button(class: 'toggle-payloads', data: _d.on.click.run('$showPayloads = !$showPayloads').to_h) do
                        span(data: { text: '$showPayloads ? "Hide Payloads" : "Show Payloads"' })
                      end
                    end
                  end
                end
              end
              div class: 'list' do
                @events.each do |event|
                  MessageRow(
                    event,
                    highlighted: (event.id == @highlighted),
                    href: helpers.url("/streams/#{event.stream_id}/#{event.id}")
                  )
                end
              end
            end
          end
        end
      end
    end
  end
end

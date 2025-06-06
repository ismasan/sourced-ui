# frozen_string_literal: true

require 'sourced/ui/dashboard/components/component'
require 'sourced/ui/dashboard/components/message_row'

module Sourced
  module UI
    module Dashboard
      module Components
        class EventList < Component
          def initialize(events:, seq: nil, reverse: true)
            @events = events
            @first_seq = @events.first&.seq
            @last_seq = @events.last&.seq
            @seq = seq || @last_seq
            @events = @events.reverse if reverse
          end

          def view_template
            div id: 'event-list' do
              div class: 'header' do
                h2 { 'History' }
                if @events.any?

                  disabled_back = @first_seq == @seq
                  disabled_forward = @last_seq == @seq

                  div(class: 'history-tools') do
                    span(class: 'pagination') do
                      button(disabled: disabled_back,
                        data: _d.on.click.get(helpers.url("/streams/#{@events.first.stream_id}/#{@seq - 1}")).to_h) do
                        safe('&larr;')
                      end
                      button(disabled: disabled_forward,
                        data: _d.on.click.get(helpers.url("/streams/#{@events.first.stream_id}/#{@seq + 1}")).to_h) do
                        safe('&rarr;')
                      end
                      small { "sequence: #{@seq} " }
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
                    highlighted: (event.seq == @seq),
                    href: helpers.url("/streams/#{event.stream_id}/#{event.seq}")
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

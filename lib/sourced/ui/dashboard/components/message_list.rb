# frozen_string_literal: true

require 'sourced/ui/dashboard/components/component'
require 'sourced/ui/dashboard/components/message_row'

module Sourced
  module UI
    module Dashboard
      module Components
        class MessageList < Component
          def initialize(messages:, position: nil)
            @messages = messages
            @first_position = @messages.first&.position
            @last_position = @messages.last&.position
            @position = position || @last_position
          end

          def view_template
            div id: 'event-list' do
              div class: 'header' do
                h2 { 'Messages' }
                if @messages.any?
                  div(class: 'history-tools') do
                    span(class: 'pagination') do
                      prev_pos = @position ? @position - 1 : nil
                      next_pos = @position ? @position + 1 : nil
                      disabled_back = @first_position == @position
                      disabled_forward = @last_position == @position

                      button(disabled: disabled_back,
                        data: _d.on.click.get(helpers.url("/log/#{prev_pos}")).to_h) do
                        safe('&larr;')
                      end
                      button(disabled: disabled_forward,
                        data: _d.on.click.get(helpers.url("/log/#{next_pos}")).to_h) do
                        safe('&rarr;')
                      end
                      small { "position: #{@position} " }
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
                @messages.reverse_each do |msg|
                  MessageRow(
                    msg,
                    highlighted: (msg.position == @position),
                    href: helpers.url("/log/#{msg.position}")
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

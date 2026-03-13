# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'
require 'sourced/ui/dashboard/components/message_list'

module Sourced
  module UI
    module Dashboard
      module Components
        class MessagePage < Component
          def initialize(messages: [], position: nil, layout: true)
            @messages = messages
            @current_message = if position
              messages.messages.find { |m| m.position == position }
            else
              messages.messages.last
            end
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
            switch_layout(title: "log position: #{@current_message&.position}") do
              div id: 'main', data: _d.signals(showPayloads: false).to_h do
                h1 { 'Global Message Log' }

                if @current_message
                  h4 { 'Current message' }
                  div(class: 'current-event') do
                    dl(class: 'event-meta prop-table') do
                      dt { 'position' }
                      dd { @current_message.position.to_s }
                      dt { 'message ID' }
                      dd { @current_message.id.to_s }
                      dt { 'type' }
                      dd { @current_message.type.to_s }
                      dt { 'created at' }
                      dd { @current_message.created_at.to_s }
                      dt { 'correlation ID' }
                      dd do
                        ref = _d.on.click.get(helpers.url("/events/#{@current_message.id}/correlation"))
                        a(href: '#', data: ref.to_h) { @current_message.correlation_id }
                      end
                      dt { 'causation ID' }
                      dd { @current_message.causation_id || '(root)' }
                      @current_message.metadata&.each do |key, value|
                        dt { key.to_s }
                        dd { value.to_s }
                      end
                    end
                    if @current_message.payload
                      div(class: 'event-payload') do
                        JSON.pretty_generate(@current_message.payload&.to_h || {})
                      end
                    end
                  end
                end
              end

              div id: 'sidebar' do
                MessageList(messages: @messages, position: @current_message&.position)
              end
            end
          end
        end
      end
    end
  end
end

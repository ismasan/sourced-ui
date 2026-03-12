# frozen_string_literal: true

require 'json'
require 'sourced/ui/dashboard/components/component'

module Sourced
  module UI
    module Dashboard
      module Components
        class MessageRow < Component
          def initialize(message, href: nil, highlighted: false)
            @message = message
            @href = href
            @is_command = message.is_a?(Sourced::CCC::Command)
            @highlighted = highlighted
            @classes = [
              'event-card',
              'fade-in',
              (@is_command ? 'command' : 'event'),
              ('highlighted' if @highlighted)
            ]
          end

          def view_template
            div(id: message.id, class: @classes) do
              div(class: 'event-header') do
                span(class: 'event-sequence') do
                  detail_ref = _d.on.click.get(@href)
                  a(id: SecureRandom.hex(8), data: detail_ref.to_h) { message.position }
                end
                producer_for(message)
                span(class: 'event-type') do
                  correlation_ref = _d.on.click.get(helpers.url("/events/#{message.id}/correlation"))
                  a(id: SecureRandom.hex(8), data: correlation_ref.to_h) { message.type }
                end
                span(class: 'event-timestamp') { message.created_at.to_s }
                span(class: 'event-author') { message.metadata[:username].to_s }
              end
              if message.payload
                div(class: 'event-payload', data: { show: '$showPayloads' }) do
                  JSON.pretty_generate(message.payload&.to_h || {})
                end
              end
            end
          end

          private

          attr_reader :message, :href, :is_command

          def producer_for(message)
            code(class: 'event-producer') { safe("#{message.metadata[:producer]} &rarr;") } if message.metadata[:producer]
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'json'
require 'sourced/ui/dashboard/components/component'

module Sourced
  module UI
    module Dashboard
      module Components
        class MessageRow < Component
          def initialize(event, href: nil, highlighted: false)
            @event = event
            @href = href
            @is_command = event.is_a?(Sourced::Command)
            @highlighted = highlighted
            @classes = [
              'event-card',
              'fade-in',
              (@is_command ? 'command' : 'event'),
              ('highlighted' if @highlighted)
            ]
          end

          def view_template
            div(id: event.id, class: @classes) do
              div(class: 'event-header') do
                span(class: 'event-sequence') do
                  detail_ref = _d.on.click.get(@href)
                  a(id: SecureRandom.hex(8), data: detail_ref.to_h) { event.seq }
                end
                producer_for(event)
                span(class: 'event-type') do
                  correlation_ref = _d.on.click.get(helpers.url("/events/#{event.id}/correlation"))
                  a(id: SecureRandom.hex(8), data: correlation_ref.to_h) { event.type }
                end
                span(class: 'event-timestamp') { event.created_at.to_s }
                span(class: 'event-author') { event.metadata[:username].to_s }
              end
              if event.payload
                div(class: 'event-payload', data: { show: '$showPayloads' }) do
                  JSON.pretty_generate(event.payload&.to_h || {})
                end
              end
            end
          end

          private

          attr_reader :event, :href, :is_command

          def producer_for(event)
            code(class: 'event-producer') { safe("#{event.metadata[:producer]} &rarr;") } if event.metadata[:producer]
          end
        end
      end
    end
  end
end


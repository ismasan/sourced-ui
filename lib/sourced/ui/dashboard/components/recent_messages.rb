# frozen_string_literal: true

require 'date'
require 'sourced/ui/dashboard/components/component'
require 'sourced/ui/dashboard/components/message_row'

module Sourced
  module UI
    module Dashboard
      module Components
        # The system page's latest messages, the latest first: a row each, as
        # a machine instance's feed has them (a dot coloured by its kind, its
        # type, its log position and time), linked to it in the log. With
        # the reactor that produced it, if it says.
        #
        # Its own element (#event-list), patched as messages arrive.
        class RecentMessages < Component
          # @param messages [Sourced::ReadResult] the latest, in descending order
          def initialize(messages:)
            @messages = messages
            @today = Date.today
          end

          def view_template
            div(id: 'event-list') do
              div(class: 'header') { h2 { 'Recent messages' } }
              div(class: 'list') do
                ol(class: 'feed-list') { @messages.each { row(it) } }
              end
            end
          end

          private

          def row(message)
            stamp = message.created_at.localtime
            li(class: "feed-item feed-item--#{MessageRow.kind(message)}") do
              a(href: helpers.url("/log/#{message.position}"), class: 'feed-item__link',
                title: "#{message.type} · #{stamp.strftime('%Y-%m-%d %H:%M:%S')}") do
                span(class: 'feed-item__dot', aria: { hidden: 'true' })
                if (producer = message.metadata[:producer])
                  span(class: 'feed-item__source') do
                    plain producer.to_s
                    span(class: 'feed-item__arrow', aria: { hidden: 'true' }) { safe(' &rarr;') }
                  end
                end
                # Its namespace muted, so the name it ends with leads.
                namespace, dot, name = message.type.rpartition('.')
                span(class: 'feed-item__name') do
                  span(class: 'feed-item__ns') { "#{namespace}#{dot}" } unless namespace.empty?
                  plain name
                end
                span(class: 'feed-item__pos') { message.position.to_s }
                time(class: 'feed-item__time', datetime: message.created_at.utc.iso8601) { moment(stamp) }
              end
            end
          end

          # Today's by the time, older ones by the day.
          def moment(stamp)
            stamp.to_date == @today ? stamp.strftime('%H:%M:%S') : stamp.strftime('%b %-d')
          end
        end
      end
    end
  end
end

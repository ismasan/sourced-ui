# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        class SystemPage < Component
          # @param registered [Array<String>] the group_ids of the reactors registered now
          def initialize(stats:, registered:, messages: [])
            @stats = stats
            @registered = registered
            @messages = messages
          end

          def view_template
            Layout(title: 'Sourced') do
              div id: 'container' do
                div id: 'main' do
                  h1 { 'Sourced Dashboard' }
                  render Consumers.new(stats: @stats, registered: @registered)
                end
                div id: 'sidebar' do
                  render Components::MessageList.recent(messages: @messages)
                end
              end

              onload = _d.init.get(helpers.url('/updates'))
              div(data: onload.to_h)
            end
          end

          class Messages < Component
            def initialize(messages:)
              @messages = messages.messages
            end

            def view_template
              div(id: 'messages') do
                h2 { 'Recent messages' }
                ul(class: 'streams-list') do
                  @messages.each do |msg|
                    li do
                      h5 do
                        span(class: 'seq') { msg.position }
                        a(href: helpers.url("/log/#{msg.position}")) { msg.type }
                      end
                      div(class: 'stream-details') do
                        small(class: 'updated-at') { msg.created_at.to_s }
                      end
                    end
                  end
                end
              end
            end
          end

          class Consumers < Component
            def initialize(stats:, registered:)
              @tip = stats.max_position
              @groups = stats.groups
              @registered = registered
            end

            def view_template
              div(id: 'consumers', class: 'consumers') do
                div(class: 'stream-container') do
                  div(class: 'stream-label') do
                    strong { 'Global Message Log' }
                  end
                  div(class: 'stream-bar global-stream') do
                    div(class: 'progress-marker', style: 'width: 100%') do
                      div(class: 'tooltip tooltip-max') { "tip: #{@tip}" }
                    end
                  end
                end

                @groups.each do |group|
                  render GroupCard.new(group:, tip: @tip, registered: @registered.include?(group[:group_id]))
                end
              end
            end
          end

          # A consumer group's status, controls and how far through the log
          # it is. Its name links to the reactor's page unless +link+ is false.
          #
          # A group no registered reactor has (its class is gone, its offsets
          # left in the store) is drawn greyed out, with nothing to act on: no
          # controls, no link.
          class GroupCard < Component
            # The card's element id, which updates patch by.
            def self.dom_id(group_id) = "group-#{group_id.gsub(/[^A-Za-z0-9_-]/, '-')}"

            def initialize(group:, tip:, link: true, registered: true)
              @group = group
              @link = link && registered
              @registered = registered
              oldest = group[:oldest_processed]
              newest = group[:newest_processed]
              @min = oldest.positive? ? ((oldest.to_f / tip) * 100) : 0
              @max = newest.positive? ? ((1 - (newest.to_f / tip)) * 100) : 0
            end

            def view_template
              group = @group
              status_class = if !@registered then 'unregistered'
                             elsif group[:retry_at] then 'retrying'
                             else group[:status]
                             end
              div(id: self.class.dom_id(group[:group_id]), class: ['stream-container', "consumer-#{status_class}"]) do
                div(class: 'stream-label') do
                  strong do
                    if @link
                      a(href: helpers.url("/reactors/#{Rack::Utils.escape_path(group[:group_id])}"), class: 'group-link') { group[:group_id] }
                    else
                      span { group[:group_id] }
                    end
                    if @registered
                      span(class: 'status') do
                        span { group[:status] }
                        if group[:retry_at]
                          span { " (retrying at #{group[:retry_at]})" }
                        end
                      end
                    else
                      span(class: 'status', title: 'No registered reactor has this group: these are its stored offsets') { 'not registered' }
                    end
                  end
                  render_controls(group) if @registered
                  small { " (#{group[:partition_count]} partitions)" }
                  if group[:status] == 'failed' && group[:error_context]&.any?
                    small(class: 'error-context') do
                      ctx = group[:error_context]
                      if ctx[:exception_class]
                        span { "#{ctx[:exception_class]}: #{ctx[:exception_message]}" }
                      end
                    end
                  end
                end
                div(class: 'stream-bar') do
                  div(class: 'lower-range', style: "width:#{@min}%") do
                    div(class: 'tooltip') { group[:oldest_processed] }
                  end
                  div(class: 'upper-range', style: "width:#{@max}%") do
                    div(class: 'tooltip') { group[:newest_processed] }
                  end
                end
              end
            end

            private def render_controls(group)
              if group[:status] == 'stopped' || group[:status] == 'failed'
                command Dashboard::ResumeConsumerGroup do |f|
                  f.payload_fields(group_id: group[:group_id])
                  button(type: 'submit', class: 'btn btn-resume') { 'Resume' }
                end
              else
                command Dashboard::StopConsumerGroup do |f|
                  f.payload_fields(group_id: group[:group_id])
                  button(type: 'submit', class: 'btn btn-stop') { 'Stop' }
                end
              end

              command Dashboard::ResetConsumerGroup do |f|
                f.payload_fields(group_id: group[:group_id])
                button(type: 'submit', class: 'btn btn-reset') { 'Reset' }
              end
            end
          end
        end
      end
    end
  end
end

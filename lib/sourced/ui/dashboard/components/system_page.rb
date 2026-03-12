# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        class SystemPage < Component
          def initialize(stats:, messages: [])
            @stats = stats
            @messages = messages
          end

          def view_template
            Layout(title: 'Sourced') do
              div id: 'container' do
                div id: 'main' do
                  h1 { 'Sourced Dashboard' }
                  render Consumers.new(stats: @stats)
                end
                div id: 'sidebar' do
                  render Messages.new(messages: @messages)
                end
              end

              onload = _d.init.get(helpers.url('/updates'))
              div(data: onload.to_h)
            end
          end

          class Messages < Component
            def initialize(messages:)
              @messages = messages
            end

            def view_template
              div(id: 'messages') do
                h2 { 'Recent messages' }
                ul(class: 'streams-list') do
                  @messages.reverse_each do |msg|
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
            def initialize(stats:)
              @tip = stats.max_position
              @groups = stats.groups.map do |g|
                oldest = g[:oldest_processed]
                newest = g[:newest_processed]
                min = oldest.positive? ? ((oldest.to_f / stats.max_position) * 100) : 0
                max = newest.positive? ? ((1 - (newest.to_f / stats.max_position)) * 100) : 0
                g.merge(min:, max:)
              end
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
                  status_class = group[:retry_at] ? 'retrying' : group[:status]
                  div(class: ['stream-container', "consumer-#{status_class}"]) do
                    div(class: 'stream-label') do
                      strong do
                        span { group[:group_id] }
                        span(class: 'status') do
                          span { group[:status] }
                          if group[:retry_at]
                            span { " (retrying at #{group[:retry_at]})" }
                          end
                        end
                      end
                      if group[:status] == 'stopped' || group[:status] == 'failed'
                        form(data: _d.on.submit.post(helpers.url('/consumer-groups/resume'), content_type: 'form').to_h) do
                          input(type: 'hidden', name: 'group_id', value: group[:group_id])
                          button(type: 'submit', class: 'btn btn-resume') { 'Resume' }
                        end
                      else
                        form(data: _d.on.submit.post(helpers.url('/consumer-groups/stop'), content_type: 'form').to_h) do
                          input(type: 'hidden', name: 'group_id', value: group[:group_id])
                          button(type: 'submit', class: 'btn btn-stop') { 'Stop' }
                        end
                      end

                      form(data: _d.on.submit.post(helpers.url('/consumer-groups/reset'), content_type: 'form').to_h) do
                        input(type: 'hidden', name: 'group_id', value: group[:group_id])
                        button(type: 'submit', class: 'btn btn-reset') { 'Reset' }
                      end
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
                      div(class: 'lower-range', style: "width:#{group[:min]}%") do
                        div(class: 'tooltip') { group[:oldest_processed] }
                      end
                      div(class: 'upper-range', style: "width:#{group[:max]}%") do
                        div(class: 'tooltip') { group[:newest_processed] }
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

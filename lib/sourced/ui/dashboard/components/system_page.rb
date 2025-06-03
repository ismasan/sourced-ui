# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        class SystemPage < Component
          def initialize(stats:)
            @stats = stats
          end

          def view_template
            Layout(title: 'Sourced') do
              div id: 'container' do
                div id: 'main' do
                  h1 { 'Sourced Dashboard' }
                  render Consumers.new(stats: @stats)
                end
                div id: 'sidebar' do
                  form(data: {'on-submit' => %(@get('#{helpers.url('/sourced/correlation')}', {contentType: 'form'}))}) do
                    input(type: 'text', placeholder: 'Event ID', name: 'event_id')
                    button(type: 'submit') { 'Go' }
                  end
                  div(id: 'events-tree')
                end
              end

              onload = { 'on-load' => %(@get('#{helpers.url('/updates')}')) }
              # onload needs to be at the end
              # to make sure to collect all signals on the page
              div(data: onload)
            end
          end

          class Consumers < Component
            WIDTH = 1000

            def initialize(stats:)
              @tip = stats.max_global_seq
              @total_streams = stats.stream_count
              @groups = stats.groups.map do |g|
                min = (g[:oldest_processed].to_f / stats.max_global_seq) * WIDTH
                max = (1 - (g[:newest_processed].to_f / stats.max_global_seq)) * WIDTH
                g.merge(min:, max:)
              end
            end

            def view_template
              div(id: 'consumers', class: 'consumers', style: "width:#{WIDTH}px") do
                div(class: 'stream-container') do
                  div(class: 'stream-label') do
                    strong { 'Global Event Stream' }
                    small { " (#{@total_streams} streams)" }
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
                      if group[:status] == 'stopped'
                        form(data: {'on-submit' => %(@post('#{helpers.url('/sourced/consumer-groups/resume')}', {contentType: 'form'}))}) do
                          input(type: 'hidden', name: 'group_id', value: group[:group_id])
                          button(type: 'submit') { 'Resume' }
                        end
                      else
                        form(data: {'on-submit' => %(@post('#{helpers.url('/sourced/consumer-groups/stop')}', {contentType: 'form'}))}) do
                          input(type: 'hidden', name: 'group_id', value: group[:group_id])
                          button(type: 'submit') { 'Stop' }
                        end
                      end

                      form(data: {'on-submit' => %(@post('#{helpers.url('/sourced/consumer-groups/reset')}', {contentType: 'form'}))}) do
                        input(type: 'hidden', name: 'group_id', value: group[:group_id])
                        button(type: 'submit') { 'Reset' }
                      end
                      small { " (#{group[:stream_count]} streams)" }
                    end
                    div(class: 'stream-bar') do
                      div(class: 'lower-range', style: "width:#{group[:min]}px") do
                        div(class: 'tooltip') { group[:oldest_processed] }
                      end
                      div(class: 'upper-range', style: "width:#{group[:max]}px") do
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

# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        class SystemPage < Component
          def initialize(stats:, streams: [])
            @stats = stats
            @streams = streams
          end

          def view_template
            Layout(title: 'Sourced') do
              div id: 'container' do
                div id: 'main' do
                  h1 { 'Sourced Dashboard' }
                  render Consumers.new(stats: @stats)
                end
                div id: 'sidebar' do
                  render Streams.new(streams: @streams)
                end
              end

              # onload = { 'on-load' => %(@get('#{helpers.url('/updates')}')) }
              onload = _d.on.load.get(helpers.url('/updates'))
              # onload needs to be at the end
              # to make sure to collect all signals on the page
              div(data: onload.to_h)
            end
          end

          class Streams < Component
            def initialize(streams:)
              @streams = streams
            end

            def view_template
              div(id: 'streams') do
                h2 { 'Recent streams' }
                ul(class: 'streams-list') do
                  @streams.each do |stream|
                    li do
                      h5 do
                        span(class: 'seq') { stream.seq }
                        a(href: helpers.url("/streams/#{stream.stream_id}")) { stream.stream_id }
                      end
                      div(class: 'stream-details') do
                        small(class: 'updated-at') { stream.updated_at.to_s }
                      end
                    end
                  end
                end
              end
            end
          end

          class Consumers < Component
            WIDTH = 800

            def initialize(stats:, width: WIDTH)
              @tip = stats.max_global_seq
              @total_streams = stats.stream_count
              @width = width
              @groups = stats.groups.map do |g|
                min = (g[:oldest_processed].to_f / stats.max_global_seq) * width
                max = (1 - (g[:newest_processed].to_f / stats.max_global_seq)) * width
                g.merge(min:, max:)
              end
            end

            def view_template
              div(id: 'consumers', class: 'consumers', style: "width:#{@width}px") do
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
                        form(data: _d.on.submit.post(helpers.url('/consumer-groups/resume'), content_type: 'form').to_h) do
                          input(type: 'hidden', name: 'group_id', value: group[:group_id])
                          button(type: 'submit') { 'Resume' }
                        end
                      else
                        form(data: _d.on.submit.post(helpers.url('/consumer-groups/stop'), content_type: 'form').to_h) do
                          input(type: 'hidden', name: 'group_id', value: group[:group_id])
                          button(type: 'submit') { 'Stop' }
                        end
                      end

                      form(data: _d.on.submit.post(helpers.url('/consumer-groups/reset'), content_type: 'form').to_h) do
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

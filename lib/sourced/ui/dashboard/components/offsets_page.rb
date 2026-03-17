# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        class OffsetsPage < Component
          def initialize(result:, groups: [], selected_group: nil)
            @offsets = result.offsets
            @total_count = result.total_count
            @groups = groups
            @selected_group = selected_group
          end

          def view_template
            Layout(title: 'Offsets') do
              div id: 'container' do
                div id: 'main' do
                  h1 { 'Offsets' }
                  small { "#{@total_count} total" }

                  form(method: 'get', action: helpers.url('/offsets'), class: 'offsets-filter') do
                    label(for: 'group_id') { 'Consumer group' }
                    select(name: 'group_id', id: 'group_id') do
                      option(value: '') { 'All groups' }
                      @groups.each do |g|
                        opts = { value: g[:group_id] }
                        opts[:selected] = true if g[:group_id] == @selected_group
                        option(**opts) { g[:group_id] }
                      end
                    end
                    button(type: 'submit') { 'Filter' }
                  end

                  if @offsets.any?
                    table(class: 'offsets-table') do
                      thead do
                        tr do
                          th { 'Group' }
                          th { 'Status' }
                          th { 'Partition' }
                          th { 'Position' }
                          th { 'Claimed' }
                          th { 'Claimed By' }
                          th { 'Claimed At' }
                        end
                      end
                      tbody do
                        @offsets.each do |offset|
                          tr do
                            td { offset[:group_name] }
                            td do
                              status = offset[:group_status]
                              span(class: "status-badge status-#{status}") { status }
                            end
                            td(class: 'mono') { offset[:partition_key] }
                            td(class: 'mono') { offset[:last_position].to_s }
                            td do
                              if offset[:claimed]
                                span(class: 'status-badge status-claimed') { 'yes' }
                              else
                                span(class: 'status-badge status-unclaimed') { 'no' }
                              end
                            end
                            td(class: 'mono') { offset[:claimed_by]&.to_s || '-' }
                            td { offset[:claimed_at]&.to_s || '-' }
                          end
                        end
                      end
                    end

                    if @offsets.size >= 50
                      next_id = @offsets.last[:id] + 1
                      group_param = @selected_group ? "&group_id=#{@selected_group}" : ''
                      div(class: 'pagination') do
                        a(href: helpers.url("/offsets?#{group_param}"), class: 'pagination-link') { 'First' }
                        a(href: helpers.url("/offsets?from_id=#{next_id}#{group_param}"), class: 'pagination-link') { 'Next' }
                      end
                    end
                  else
                    p { 'No offsets found.' }
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

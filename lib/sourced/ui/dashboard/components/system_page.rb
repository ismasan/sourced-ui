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
                div(class: 'stream-container global-log') do
                  div(class: 'stream-label') do
                    strong { 'Global Message Log' }
                  end
                  div(class: 'stream-bar global-stream') do
                    div(class: 'progress-marker', style: 'width: 100%') do
                      div(class: 'tooltip tooltip-max') { "tip: #{@tip}" }
                    end
                  end
                end

                Namespace.partition(@groups).each do |namespace, groups|
                  if namespace
                    render Namespace.new(namespace:, groups:, tip: @tip, registered: @registered)
                  else
                    groups.each { |group| render group_card(group) }
                  end
                end
              end
            end

            private def group_card(group)
              GroupCard.new(group:, tip: @tip, registered: @registered.include?(group[:group_id]))
            end
          end

          # The consumer groups sharing the first segment of their group id
          # (+cross_post+ in +cross_post.connections.linked_in+), in a box
          # collapsed by default to a summary: how many groups, and how many
          # are failed, stopped or retrying, which colours the box (in that
          # order of precedence) so that such a group is noticed without
          # opening it.
          #
          # The box is a +<details>+ whose +open+ attribute Datastar keeps
          # across the morphs of +/updates+, so one the operator opened stays
          # open while its cards update.
          class Namespace < Component
            # Groups by namespace, in the order of their first group: a group
            # whose id has one segment stands alone, under a nil namespace.
            #
            # @param groups [Array<Hash>] Store#stats groups
            # @return [Array<[String, Array<Hash>]>, Array<[nil, Array<Hash>]>]
            def self.partition(groups)
              groups
                .chunk_while { |a, b| namespace_of(a) && namespace_of(a) == namespace_of(b) }
                .map { |chunk| [namespace_of(chunk.first), chunk] }
            end

            def self.namespace_of(group)
              head, rest = group[:group_id].split('.', 2)
              head if rest
            end

            def self.dom_id(namespace) = "namespace-#{namespace.gsub(/[^A-Za-z0-9_-]/, '-')}"

            # The states a namespace counts and is tinted by, most pressing first.
            COUNTED_STATES = [
              ConsumerGroupMachine::Failed,
              ConsumerGroupMachine::Stopped,
              ConsumerGroupMachine::Retrying
            ].freeze

            def initialize(namespace:, groups:, tip:, registered:)
              @namespace = namespace
              @groups = groups
              @tip = tip
              @registered = registered
            end

            def view_template
              details(id: self.class.dom_id(@namespace), class: ['namespace', "namespace-#{state}"], data: { preserve_attr: 'open' }) do
                summary(class: 'namespace-summary') do
                  strong(class: 'namespace-name') { title }
                  code(class: 'namespace-id') { @namespace }
                  span(class: 'namespace-count') { pluralize(@groups.size, 'group') }
                  status_counts.each do |status, count|
                    span(class: "namespace-badge namespace-badge--#{status}") { "#{count} #{status}" } if count.positive?
                  end
                end
                div(class: 'namespace-groups') do
                  @groups.each do |group|
                    render GroupCard.new(group:, tip: @tip, registered: registered?(group))
                  end
                end
              end
            end

            private

            def registered?(group) = @registered.include?(group[:group_id])

            # How many registered groups are in each of {COUNTED_STATES}, by
            # state name, in that order of precedence.
            # @return [Hash{String => Integer}]
            def status_counts
              @status_counts ||= begin
                machines = @groups.select { registered?(it) }.map { GroupCard.machine(it) }
                COUNTED_STATES.to_h do |state|
                  [state.state_name.to_s, machines.count { state === it }]
                end
              end
            end

            # The most pressing status any of the groups is in, which tints
            # the box; 'ok' when none is.
            def state = status_counts.find { |_, count| count.positive? }&.first || 'ok'

            # The module the groups' classes share (+CrossPost+), read off
            # their labels; the namespace id when they share none.
            def title
              heads = @groups.map { |g| g[:label].to_s.split('::').first }.uniq
              heads.size == 1 && heads.first && !heads.first.empty? ? heads.first : @namespace
            end

            def pluralize(count, word) = "#{count} #{word}#{'s' unless count == 1}"
          end

          # A consumer group's status, controls and how far through the log
          # it is. Its name links to the reactor's page unless +link+ is false.
          #
          # The group's status is a state of Sourced::ConsumerGroupMachine:
          # the card reads it as that machine's configuration, and renders
          # within it (+with_machine+) only the operator commands it accepts.
          #
          # A group no registered reactor has (its class is gone, its offsets
          # left in the store) is drawn greyed out, with nothing to act on: no
          # controls, no link.
          class GroupCard < Component
            # The card's element id, which updates patch by.
            def self.dom_id(group_id) = "group-#{group_id.gsub(/[^A-Za-z0-9_-]/, '-')}"

            # The group's status as a Sourced::ConsumerGroupMachine
            # configuration, which state constants match in +case+ / +in+.
            # @param group [Hash] a Store#stats group
            # @return [Sourced::Machine::Configuration]
            def self.machine(group) = ConsumerGroupMachine.configuration([group[:status]])

            # Cassette-deck glyphs for the buttons, as SVG paths on a 10x10 box.
            ICONS = {
              play: 'M2 1 L9 5 L2 9 Z',
              stop: 'M1.5 1.5 H8.5 V8.5 H1.5 Z',
              fast_forward: 'M0.5 1.5 L5 5 L0.5 8.5 Z M5 1.5 L9.5 5 L5 8.5 Z',
              rewind: 'M9.5 1.5 L5 5 L9.5 8.5 Z M5 1.5 L0.5 5 L5 8.5 Z'
            }.freeze

            # The operator commands, in the order their buttons show, with
            # their label, icon and class. Start resumes (plays) a halted
            # group, and Reset rewinds one to process the log again.
            CONTROLS = {
              ConsumerGroupMachine::Start => ['Resume', :play, 'btn-resume'],
              ConsumerGroupMachine::Stop => ['Stop', :stop, 'btn-stop'],
              ConsumerGroupMachine::Reset => ['Reset', :rewind, 'btn-reset']
            }.freeze

            # Start on a retrying group fast-forwards past its wait.
            RETRY_NOW = ['Retry now', :fast_forward, 'btn-resume'].freeze

            def initialize(group:, tip:, link: true, registered: true)
              @group = group
              @link = link && registered
              @registered = registered
              @machine = self.class.machine(group) if registered
              oldest = group[:oldest_processed]
              newest = group[:newest_processed]
              @min = oldest.positive? ? ((oldest.to_f / tip) * 100) : 0
              @max = newest.positive? ? ((1 - (newest.to_f / tip)) * 100) : 0
            end

            def view_template
              group = @group
              state = @registered ? @machine.value.state_name.to_s : 'unregistered'
              div(id: self.class.dom_id(group[:group_id]), class: ['stream-container', "consumer-#{state}"]) do
                div(class: 'stream-label') do
                  strong do
                    label = group[:label] || group[:group_id]
                    if @link
                      a(href: helpers.url("/reactors/#{Rack::Utils.escape_path(group[:group_id])}"), class: 'group-link', title: group[:group_id]) { label }
                    else
                      span(title: group[:group_id]) { label }
                    end
                    if @registered
                      span(class: 'status') { state }
                    else
                      span(class: 'status', title: 'No registered reactor has this group: these are its stored offsets') { 'not registered' }
                    end
                  end
                  with_machine(@machine) { render_controls } if @registered
                  small { " (#{group[:partition_count]} partitions)" }
                  render_context if @registered
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

            private

            def error_context = @group[:error_context] || {}

            def render_controls
              available = @machine.available_commands
              CONTROLS.each_key do |cmd_class|
                next unless available.include?(cmd_class)

                command cmd_class, key: @group[:group_id] do |f|
                  f.payload_fields(group_id: @group[:group_id])
                  label, icon, css = control(cmd_class)
                  button(type: 'submit', class: "btn #{css}") do
                    svg(class: 'btn-icon', viewBox: '0 0 10 10', aria: { hidden: 'true' }) { |s| s.path(d: ICONS.fetch(icon)) }
                    plain label
                  end
                end
              end
            end

            # The label, icon and class of +cmd_class+'s button, in this state.
            def control(cmd_class)
              return RETRY_NOW if cmd_class == ConsumerGroupMachine::Start && (@machine in ConsumerGroupMachine::Retrying)

              CONTROLS.fetch(cmd_class)
            end

            # Why a group halted or is retrying: the exception it failed
            # with, or the operator's stop message.
            def render_context
              text = case @machine
                     in ConsumerGroupMachine::Retrying | ConsumerGroupMachine::Failed
                       "#{error_context[:exception_class]}: #{error_context[:exception_message]}" if error_context[:exception_class]
                     in ConsumerGroupMachine::Stopped
                       error_context[:message]
                     else nil
                     end
              return unless text

              small(class: 'error-context') do
                if @group[:retry_at] && (@machine in ConsumerGroupMachine::Retrying)
                  span(class: 'retry-at') { "retry ##{error_context[:retry_count]}, next at #{@group[:retry_at].strftime('%H:%M:%S %Z')} — " }
                end
                span { text }
              end
            end
          end

          # A failed group's stored exception and backtrace, in a card of its
          # own after its GroupCard, collapsed. Datastar keeps +open+ across
          # the morphs that update the card, so a panel the operator opened
          # stays open. Frames in installed gems are dimmed, so the app's own
          # stand out.
          #
          # A group that isn't failed renders a hidden placeholder with the
          # same id, for updates to patch should the group fail.
          class FailureCard < Component
            def self.dom_id(group_id) = "#{GroupCard.dom_id(group_id)}-failure"

            def initialize(group:)
              @group = group
            end

            def view_template
              id = self.class.dom_id(@group[:group_id])
              error_context = @group[:error_context] || {}
              failed = (GroupCard.machine(@group) in ConsumerGroupMachine::Failed)
              return div(id:, hidden: true) unless failed && error_context[:exception_class]

              backtrace = Array(error_context[:exception_backtrace])
              details(id:, class: 'failure-details', data: { preserve_attr: 'open' }) do
                summary(class: 'failure-summary') do
                  span { 'Exception and backtrace' }
                  small { "#{backtrace.size} #{backtrace.size == 1 ? 'frame' : 'frames'}" }
                end
                div(class: 'failure-body') do
                  p(class: 'failure-exception') do
                    strong { error_context[:exception_class] }
                    plain ": #{error_context[:exception_message]}"
                  end
                  if backtrace.any?
                    ol(class: 'failure-backtrace') do
                      backtrace.each do |frame|
                        li(class: ('is-gem' if frame.include?('/gems/'))) { frame }
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

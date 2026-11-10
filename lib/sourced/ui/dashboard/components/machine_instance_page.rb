# frozen_string_literal: true

require 'json'
require 'sourced/ui/components'
require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        # A Sourced::Machine instance's page, at
        # /reactors/:group_id/instance?<partition key>=<value>...: its
        # statechart lit where the instance is, and its partition's messages
        # in the sidebar. A message picked there travels back to it (+at+, its
        # log position): the chart shows the instance as it was once it had
        # evolved up to it. With none picked, the page follows the instance,
        # patched as new messages arrive.
        class MachineInstancePage < Component
          # @param reactor [Class<Sourced::Machine>]
          # @param reactors [Array<Class>] the registered reactors, for links to the machines it starts
          # @param timeline [MachineTimeline]
          # @param at [Integer, nil] the log position travelled to; nil for the latest
          def initialize(reactor:, reactors:, timeline:, at: nil, layout: true)
            @reactor = reactor
            @reactors = reactors
            @timeline = timeline
            @at = at
            @layout = layout
          end

          def view_template
            return render_page unless @layout

            Layout(title: "#{@reactor.group_label} #{values_label} · Sourced") do
              div(id: 'container') { render_page }
              # Messages are picked in place, with their URL pushed: going back
              # or forward loads the page the browser lands on.
              script { raw safe("addEventListener('popstate', () => location.reload())") }
            end
          end

          # This page's URL: the instance, at +at+.
          def href = MachineInstance.href(helpers, @reactor, @timeline.values, at: @at)

          private

          def render_page
            div(id: 'reactor', class: 'reactor reactor--instance') do
              render_header
              # Following the latest: patched with the instance as messages
              # arrive. A message picked aborts it (see MachineInstance#travel).
              if @at.nil?
                updates = MachineInstance.href(helpers, @reactor, @timeline.values, path: '/instance/updates',
                                                                                      after: @timeline.last_position)
                div(id: 'machine-follow', hidden: true,
                    data: { init: "@get(#{updates.to_json}, {requestCancellation: (window.sourcedFollow = new AbortController())})" })
              end
              render MachineInstance.new(reactor: @reactor, reactors: @reactors, timeline: @timeline, at: @at)
            end
          end

          def render_header
            base = helpers.url("/reactors/#{Rack::Utils.escape_path(@reactor.group_id)}")
            header(class: 'reactor__header') do
              nav(class: 'crumbs', aria: { label: 'Breadcrumb' }) do
                a(href: helpers.url('/')) { 'System' }
                span(class: 'crumbs__sep', aria: { hidden: 'true' }) { '/' }
                span { 'Reactors' }
                span(class: 'crumbs__sep', aria: { hidden: 'true' }) { '/' }
                a(href: base) { @reactor.group_label }
              end

              div(class: 'reactor__title') do
                h1 { @reactor.group_label }
                span(class: 'kind-badge kind-badge--machine') { 'instance' }
              end

              dl(class: 'facts') do
                fact('Class') { code { @reactor.name.to_s } }
                @timeline.values.each do |key, value|
                  fact(key.to_s) { code(class: 'key') { value.to_s } }
                end
              end
            end
          end

          def fact(term, &)
            div(class: 'facts__item') do
              dt { term }
              dd(&)
            end
          end

          def values_label = @timeline.values.values.join(', ')
        end

        # The instance at a log position: its statechart, what it's in and
        # accepts there, and its partition's messages to travel between. Its
        # own element (#machine-instance), patched as the instance moves.
        class MachineInstance < Component
          # An instance page's URL: its partition values in the query, then +at+.
          def self.href(helpers, reactor, values, path: '/instance', **query)
            query = values.transform_keys(&:to_s).merge(query.compact.transform_keys(&:to_s))
            helpers.url("/reactors/#{Rack::Utils.escape_path(reactor.group_id)}#{path}?#{Rack::Utils.build_query(query)}")
          end

          def initialize(reactor:, reactors:, timeline:, at: nil)
            @reactor = reactor
            @reactors = reactors
            @timeline = timeline
            @at = at
            @instance = timeline.at(at)
            @step = at ? timeline.step_at(at) : timeline.steps.last
            @definition = reactor.to_h
            @labels = MachineChart.command_labels(@definition)
          end

          def view_template
            div(id: 'machine-instance', class: 'reactor__layout') do
              div(class: 'reactor__main') do
                render_chart
                render_state
                render_message if @step
              end

              aside(class: 'reactor__aside', aria: { label: 'Messages' }) do
                render_feed
              end
            end
          end

          private

          # ---- The chart ----

          def render_chart
            figure(class: 'chart-card') do
              figcaption(class: 'chart-card__bar') do
                strong { 'Statechart' }
                span(class: 'muted') { caption }
                a(href: href, class: 'chart-card__clear', data: travel(href)) { 'Back to latest' } if @at
              end
              div(class: 'chart-card__canvas chart-card__canvas--instance') do
                href = ->(group_id) { reactor_href(group_id) if @reactors.any? { it.group_id == group_id } }
                render Sourced::UI::Components::Statechart.new(@instance, title: "#{@reactor.group_label} statechart", href:)
              end
              div(class: 'chart-card__foot') do
                details(class: 'chart-card__legend') do
                  summary { 'Legend' }
                  render Sourced::UI::Components::StatechartLegend.new
                end
              end
            end
          end

          def caption
            if @at.nil?
              @timeline.empty? ? 'No messages yet: the instance is where it starts. Following.' : 'The latest. Following.'
            elsif @step.nil?
              'Before its first message.'
            else
              "As of position #{@step.position}."
            end
          end

          # ---- Where it is ----

          def render_state
            configuration = @instance.machine
            section(class: 'panel', aria: { label: 'State' }) do
              div(class: 'panel__head') do
                h2 do
                  plain 'In '
                  paths = configuration.paths
                  if paths.empty?
                    span(class: 'muted') { 'its initial position' }
                  else
                    paths.each_with_index do |path, i|
                      plain ', ' if i.positive?
                      code { path }
                    end
                  end
                  span(class: 'type-badge type-badge--final') { 'final' } if configuration.final?
                end
              end

              div(class: 'columns') do
                accepted = @instance.available_commands.map(&:type)
                div(class: 'column column--accepts') do
                  h3 { 'Accepts' }
                  commands(accepted)
                end
                div(class: 'column column--refuses') do
                  h3 { 'Refuses' }
                  all = MachineChart.commands(@definition).reject { it[:kind] == 'event' }.map { it[:event] }
                  commands(all - accepted, refused: true)
                end

                div(class: 'column') do
                  h3 { 'Context' }
                  pre(class: 'json-block') { json(@instance.context) }
                end
              end
            end
          end

          # Commands by type, as their labels.
          def commands(types, refused: false)
            return p(class: 'muted') { 'Nothing.' } if types.empty?

            ul(class: "transition-list#{' transition-list--refused' if refused}") do
              types.each { |type| li { code(class: 'cmd cmd--command', title: type) { @labels.fetch(type) { type } } } }
            end
          end

          def render_message
            message = @step.message
            section(class: 'panel', aria: { label: 'Message' }) do
              div(class: 'panel__head') do
                h2 do
                  plain "##{message.position} "
                  code { message.type }
                end
                a(href: helpers.url("/log/#{message.position}"), class: 'panel__link') { 'In the log' }
                p(class: 'note') { message.created_at.to_s }
              end
              pre(class: 'json-block') { json(message.payload&.to_h || {}) }
            end
          end

          # ---- The sidebar: its messages ----

          # Its messages, grouped by command: each command over what it
          # appended, in log order, with the latest groups first.
          def render_feed
            steps = @timeline.steps

            section(class: 'panel panel--aside') do
              div(class: 'panel__head') do
                h2 { "Messages (#{steps.size})" }
                feed_nav(steps)
                a(href:, class: 'panel__link', data: travel(href)) { 'Latest' } if @at
              end

              # A tree: each command over what it appended, each message a link
              # to travel to it, down to where the machine starts.
              ol(class: 'feed-tree') do
                @timeline.groups.reverse_each do |group|
                  li(class: 'feed-group') do
                    ol(class: 'feed-group__messages') do
                      group.steps.each { feed_step(it, caused: !group.command.nil? && it != group.command) }
                    end
                  end
                end

                feed_item(href(at: 0), current: @step.nil?, future: false, kind: 'start', title: 'Before its first message') do
                  span(class: 'feed-item__name') { 'Start' }
                  span(class: 'feed-item__pos') { '0' }
                  # No time: a blank as wide, so its position lines up with the others'.
                  span(class: 'feed-item__time feed-item__time--blank', aria: { hidden: 'true' }) { '00:00:00' }
                end
              end
            end
          end

          # A command, or an event: indented under the command it was
          # appended for, if +caused+.
          def feed_step(step, caused:)
            message = step.message
            title = "#{message.type} · #{message.created_at.localtime.strftime('%Y-%m-%d %H:%M:%S')}"
            feed_item(href(at: step.position), current: step == @step, kind: MessageRow.kind(message), title:,
                                                future: !@step || step.position > @step.position, caused:) do
              # A state change reads as where it went: `→ hotel_chosen`.
              targets = move_targets(step)
              span(class: 'feed-item__name') { targets ? "→ #{targets.join(', ')}" : short_type(message.type) }
              span(class: 'feed-item__pos') { message.position.to_s }
              time(class: 'feed-item__time', datetime: message.created_at.utc.iso8601) do
                message.created_at.localtime.strftime('%H:%M:%S')
              end
            end
          end

          # ← and → step to the message before and after the current one (or
          # where it starts), in log order: disabled at either end.
          def feed_nav(steps)
            points = [nil, *steps] # nil: where it starts
            at = @step ? points.index(@step) : 0
            older = points[at - 1] if at.positive?
            newer = points[at + 1]

            span(class: 'pagination feed-nav') do
              nav_button('&larr;', 'Older message', at.positive? && href(at: older&.position || 0))
              nav_button('&rarr;', 'Newer message', newer && href(at: newer.position))
            end
          end

          def nav_button(arrow, label, href)
            button(type: 'button', title: label, aria: { label: }, disabled: !href,
                   data: href ? travel(href).transform_keys { it.sub('__prevent', '') } : {}) { safe(arrow) }
          end

          # A row in the tree: a dot coloured by its +kind+ (a command, a
          # state change, a data event, or where it starts), then what yields.
          def feed_item(href, current:, future:, kind:, title:, caused: false)
            classes = ['feed-item', "feed-item--#{kind}", ('is-caused' if caused), ('is-current' if current),
                       ('is-future' if future)].compact
            li(class: classes.join(' ')) do
              a(href:, title:, class: 'feed-item__link', aria: { current: current ? 'true' : nil }, data: travel(href)) do
                span(class: 'feed-item__dot', aria: { hidden: 'true' })
                yield
              end
            end
          end

          # ---- Helpers ----

          def short_type(type) = type.delete_prefix("#{@reactor.message_prefix}.")

          # The names of the states a step's message moved the machine to: those
          # it entered, or, re-entering one already active, its event's target.
          # nil for a message that isn't a state change.
          def move_targets(step)
            return step.entered.map { it.split('.').last } if step.entered.any?
            return unless step.message.class < Sourced::Machine::State

            target = step.message.payload.to_h[:target]
            [target.to_s.split('.').last] if target
          end

          def json(value)
            value = value.to_h if !value.is_a?(Hash) && value.respond_to?(:to_h)
            JSON.pretty_generate(value)
          rescue StandardError
            value.inspect
          end

          def href(at: nil) = MachineInstance.href(helpers, @reactor, @timeline.values, at:)
          def reactor_href(group_id) = helpers.url("/reactors/#{Rack::Utils.escape_path(group_id)}")

          # Fetched over Datastar, which patches the page in, instead of
          # loaded. Stops following the latest first, so its updates don't
          # overwrite the past.
          def travel(href) = { 'on:click__prevent' => "window.sourcedFollow?.abort(); @get(#{href.to_json})" }
        end
      end
    end
  end
end

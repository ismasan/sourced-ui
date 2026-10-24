# frozen_string_literal: true

require 'sourced/ui/components'
require 'sourced/ui/dashboard/components/layout'
require 'sourced/ui/dashboard/components/system_page'

module Sourced
  module UI
    module Dashboard
      module Components
        # A reactor's page: its consumer group, partitioning and the messages
        # it handles. A Sourced::Machine gets its statechart instead, its
        # states with the commands each takes, and the machines it starts or
        # is started by. A state picked on the chart or in the list is lit,
        # with what it accepts and refuses, at /reactors/:group_id/states/:state
        # (the state as its chart DOM id).
        class ReactorPage < Component
          KINDS = {
            Sourced::Machine => 'machine',
            Sourced::Decider => 'decider',
            Sourced::Projector => 'projector',
            Sourced::DurableWorkflow => 'workflow'
          }.freeze

          # @return [ReactorPage, nil] nil for a reactor or state that doesn't exist
          # @param topology [#call] returns Sourced.topology: only built for a reactor that isn't a machine
          def self.build(group_id, reactors:, stats:, topology:, state: nil, layout: true)
            reactor = reactors.find { it.group_id == group_id }
            return unless reactor

            page = new(reactor:, reactors:, stats:, topology:, state:, layout:)
            page if state.nil? || page.row
          end

          attr_reader :row

          def initialize(reactor:, reactors:, stats:, topology:, state: nil, layout: true)
            @reactor = reactor
            @topology = topology
            @reactors = reactors
            @stats = stats
            @group = stats.groups.find { it[:group_id] == reactor.group_id }
            @layout = layout
            @kind = KINDS.find { |base, _| Module === reactor && reactor <= base }&.last || 'reactor'
            return unless machine?

            @definition = reactor.to_h
            @rows = MachineChart.rows(@definition)
            @rows_by_path = @rows.to_h { [it.path, it] }
            @row = state && @rows.find { MachineChart.dom_id(it.path) == state }
            # Labels more than one command shares, told apart by their types.
            @shared_labels = MachineChart.commands(@definition).map { it[:label] }.tally.select { _2 > 1 }.keys
          end

          def view_template
            return render_page unless @layout

            Layout(title: "#{@reactor.group_label} · Sourced") do
              div(id: 'container') { render_page }
              # States are picked in place, with their URL pushed: going back
              # or forward loads the page the browser lands on.
              script { raw safe("addEventListener('popstate', () => location.reload())") }
              # Patches the consumer group's card as its stats change: after
              # Stop, Resume or Reset, and as it works through the log.
              div(data: _d.init.get("#{base_href}/updates").to_h)
            end
          end

          private

          def machine? = @kind == 'machine'

          def render_page
            div(id: 'reactor', class: 'reactor') do
              render_header
              machine? ? render_machine : render_handlers
            end
          end

          # ---- Every reactor ----

          def render_header
            header(class: 'reactor__header') do
              nav(class: 'crumbs', aria: { label: 'Breadcrumb' }) do
                a(href: helpers.url('/')) { 'System' }
                span(class: 'crumbs__sep', aria: { hidden: 'true' }) { '/' }
                span { 'Reactors' }
              end

              div(class: 'reactor__title') do
                h1 { @reactor.group_label }
                span(class: "kind-badge kind-badge--#{@kind}") { @kind }
              end

              dl(class: 'facts') do
                fact('Class') { code { @reactor.name.to_s } }
                fact('Consumer group') { code { @reactor.group_id } }
                fact('Partitioned by') { partition_keys }
                if machine?
                  fact('States') { @rows.count { it.type != 'initial' }.to_s }
                  fact('Commands') { MachineChart.commands(@definition).size.to_s }
                else
                  fact('Handles') { "#{Array(@reactor.handled_messages).size} message types" }
                end
              end

              if @group
                div(class: 'consumers reactor__group') do
                  render SystemPage::GroupCard.new(group: @group, tip: @stats.max_position, link: false)
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

          def partition_keys
            keys = Array(@reactor.partition_keys)
            return span(class: 'muted') { 'nothing' } if keys.empty?

            keys.each { |key| code(class: 'key') { key.to_s } }
          end

          def render_flow
            event_model_card(EventFlow.build(@topology.call, @reactor.group_id),
                             title: "#{@reactor.group_label} event model",
                             lead: 'What triggers it, what it decides, and what reacts downstream.')
          end

          def event_model_card(flow, title:, lead:)
            return if flow.empty?

            href = ->(group_id) { reactor_href(group_id) if @reactors.any? { it.group_id == group_id } }
            schemas = Sourced::UI::Components::EventModel.schemas?(flow)

            # Both drawings are rendered; the toggle shows one, without a request.
            figure(class: 'chart-card', data: { 'signals:schemas' => 'false' }) do
              figcaption(class: 'chart-card__bar') do
                strong { 'Event model' }
                span(class: 'muted') { lead }
                div(class: 'chart-card__tools') do
                  if schemas
                    label(class: 'switch') do
                      input(type: 'checkbox', role: 'switch', data: { 'bind:schemas' => true })
                      span(class: 'switch__track', aria: { hidden: 'true' })
                      plain 'Schemas'
                    end
                  end
                  ul(class: 'em-key', aria: { label: 'Key' }) do
                    li(class: 'em-key__item em-key__item--command') { 'Command' }
                    li(class: 'em-key__item em-key__item--event') { 'Event' }
                    li(class: 'em-key__item em-key__item--readmodel') { 'Read model' }
                    li(class: 'em-key__item em-key__item--automation') { 'Automation' }
                  end
                end
              end
              div(class: 'chart-card__canvas chart-card__canvas--plain', data: { show: '!$schemas' }) do
                render Sourced::UI::Components::EventModel.new(flow, href:, title:)
              end
              if schemas
                div(class: 'chart-card__canvas chart-card__canvas--plain', style: 'display: none', data: { show: '$schemas' }) do
                  render Sourced::UI::Components::EventModel.new(flow, href:, title: "#{title}, with message schemas", schemas: true)
                end
              end
              if flow.truncated?
                p(class: 'chart-card__note') { 'The flow goes on further downstream than shown.' }
              end
            end
          end

          def render_handlers
            render_flow
            commands, events = Array(@reactor.handled_messages).partition { Module === it && it <= Sourced::Command }

            section(class: 'panel') do
              div(class: 'panel__head') { h2 { 'Handles' } }
              div(class: 'columns') do
                message_types('Commands', commands)
                message_types('Events', events)
              end
            end
          end

          def message_types(title, list)
            div do
              h3 { "#{title} (#{list.size})" }
              next p(class: 'muted') { 'None.' } if list.empty?

              ul(class: 'type-list') do
                list.each do |klass|
                  li do
                    code { klass.type }
                    span(class: 'muted') { klass.name.to_s }
                  end
                end
              end
            end
          end

          # ---- A machine ----

          def render_machine
            div(class: 'reactor__layout') do
              div(class: 'reactor__main') do
                render_chart
                @row ? render_state : render_overview
              end

              aside(class: 'reactor__aside', aria: { label: 'States' }) do
                render_states
                render_relations
              end
            end
          end

          # A click on a state picks it: the chart ids them sc-<dom id>.
          def render_chart
            node = "evt.target.closest('.statechart__node')"
            pick = "#{node} && @get(#{"#{base_href}/states/".to_json} + #{node}.id.slice(3))"
            chart = @row ? MachineChart.highlight(@definition, @row.path) : @definition

            figure(class: 'chart-card') do
              figcaption(class: 'chart-card__bar') do
                strong { 'Statechart' }
                span(class: 'muted') { 'Click a state to see what it accepts.' }
                a(href: base_href, class: 'chart-card__clear', data: travel(base_href)) { 'Clear selection' } if @row
              end
              div(class: 'chart-card__canvas', data: { 'on:click' => pick }) do
                href = ->(group_id) { reactor_href(group_id) if @reactors.any? { it.group_id == group_id } }
                render Sourced::UI::Components::Statechart.new(chart, title: "#{@reactor.group_label} statechart", href:)
              end
              div(class: 'chart-card__foot', data: { 'signals:copied' => "''" }) do
                details(class: 'chart-card__legend') do
                  summary { 'Legend' }
                  render Sourced::UI::Components::StatechartLegend.new
                end
                copy_mermaid
              end
            end
          end

          # The machine as a Mermaid state diagram, to the clipboard. Where the
          # browser won't allow it (not over HTTPS, say), the button says so.
          def copy_mermaid
            copy = "(navigator.clipboard ? navigator.clipboard.writeText(el.dataset.mermaid) : Promise.reject())" \
                   ".then(() => $copied = 'yes', () => $copied = 'no'); setTimeout(() => $copied = '', 2000)"
            label = "$copied == 'yes' ? 'Copied' : $copied == 'no' ? 'Copy failed' : 'Copy Mermaid code'"
            button(type: 'button', class: 'btn chart-card__copy', data: { mermaid: @reactor.to_mermaid, 'on:click' => copy, text: label }) do
              'Copy Mermaid code'
            end
          end

          def render_overview
            section(class: 'panel') do
              div(class: 'panel__head') do
                h2 { 'Transitions' }
                p(class: 'muted') { 'Every command and event each state takes, and where it leads.' }
              end

              table(class: 'data-table') do
                thead do
                  tr do
                    th { 'Command' }
                    th { 'In' }
                    th { 'Leads to' }
                  end
                end
                tbody do
                  @rows.each do |row|
                    row.own.each do |t|
                      tr do
                        td { command_name(t) }
                        td { state_ref(row) }
                        td(class: 'muted') { outcome(t) }
                      end
                    end
                  end
                end
              end

              if (stop = @definition[:stop])
                p(class: 'note') do
                  plain 'Its parent can stop it from any state: '
                  code { stop[:label] }
                  plain " → #{stop[:targets].join}."
                end
              end
            end
          end

          # ---- The picked state ----

          def render_state
            accepted = @row.accepted.map { it[:event] }
            siblings = MachineChart.sibling_regions(@definition, @row.path)
              .map { |region, list| [region, list.reject { accepted.include?(it[:event]) }] }
              .reject { _2.empty? }
            maybe = siblings.flat_map(&:last).map { it[:event] }
            refused = MachineChart.commands(@definition).reject { (accepted + maybe).include?(it[:event]) }

            section(class: 'panel', aria: { label: "In #{@row.path}" }) do
              div(class: 'panel__head') do
                h2 do
                  plain 'In '
                  code { @row.path }
                  span(class: "type-badge type-badge--#{@row.type}") { @row.type }
                end
                @row.timers.each do |timer|
                  p(class: 'note') { "⏱ #{MachineChart.delay_label(timer.delay)} after entering it, a timer dispatches #{timer.commands.join(', ')}." }
                end
              end

              div(class: 'columns') do
                div(class: 'column column--accepts') do
                  h3 { 'Accepts' }
                  transitions(@row.own)
                  if @row.inherited.any?
                    h4 { 'From the states around it' }
                    transitions(@row.inherited)
                  end
                end

                if siblings.any?
                  div(class: 'column column--maybe') do
                    h3 { 'Depends on its sibling regions' }
                    p(class: 'note') { 'Accepted while the other regions are where these are taken.' }
                    ul(class: 'transition-list') do
                      siblings.each do |region, list|
                        li do
                          span(class: 'region-name') { region.split('.').last }
                          list.each { command_name(it) }
                        end
                      end
                    end
                  end
                end

                div(class: 'column column--refuses') do
                  h3 { 'Refuses' }
                  transitions(refused, refused: true)
                end
              end
            end

            event_model_card(
              MachineSlice.build(@reactor, @row.path, @topology.call),
              title: "#{@reactor.group_label} in #{@row.path}, event model",
              lead: "What it takes in #{@row.name}, what that appends, and what reacts downstream."
            )
          end

          def transitions(list, refused: false)
            return p(class: 'muted') { 'Nothing.' } if list.empty?

            ul(class: "transition-list#{' transition-list--refused' if refused}") do
              list.each do |t|
                li do
                  command_name(t)
                  span(class: 'muted') { " #{outcome(t)}" } unless refused
                end
              end
            end
          end

          # ---- The sidebar ----

          def render_states
            section(class: 'panel panel--aside') do
              div(class: 'panel__head') do
                h2 { 'States' }
                a(href: base_href, class: 'panel__link', data: travel(base_href)) { 'All transitions' } if @row
              end
              state_list(@definition, class: 'state-tree')
            end
          end

          # The chart's states as it nests them, each with the commands it
          # takes itself: a compound state's sub-states under it, and a
          # parallel state's regions under it, each with its own.
          def state_list(region, **attrs)
            ul(**attrs) do
              region[:states].each_value do |node|
                next if node[:type] == 'history'

                row = @rows_by_path.fetch(node[:id])
                li do
                  state_link(row)
                  if row.own.any?
                    ul(class: 'chips') do
                      row.own.each { |t| li(title: outcome(t)) { command_name(t) } }
                    end
                  end

                  case node[:type]
                  in 'parallel'
                    ul do
                      MachineChart.regions(node).each do |sub|
                        li do
                          span(class: 'region-name') { sub[:key] }
                          state_list(sub)
                        end
                      end
                    end
                  in 'compound' then state_list(node)
                  else nil
                  end
                end
              end
            end
          end

          def state_link(row)
            current = row == @row
            href = current ? base_href : state_href(row)
            a(href:, class: "state-link state-link--#{row.type}", aria: { current: current ? 'true' : nil }, data: travel(href)) do
              span(class: 'state-link__name') { row.name }
              span(class: 'state-link__timer', title: "Timer: #{row.timers.map(&:label).join('; ')}") { '⏱' } if row.timers.any?
              span(class: "type-badge type-badge--#{row.type}") { row.type } unless row.type == 'atomic'
            end
          end

          def state_ref(row)
            a(href: state_href(row), class: 'state-ref', data: travel(state_href(row))) { row.path }
          end

          # The machines this one is started by, starts and mounts.
          def render_relations
            parents = machines.filter_map do |machine|
              list = MachineChart.starters(machine.to_h).fetch(@reactor.group_id, [])
              [machine, list] if list.any?
            end
            children = @definition[:children]
            mounts = MachineChart.mounts(@definition)
            return if parents.empty? && children.empty? && mounts.empty?

            section(class: 'panel panel--aside') do
              div(class: 'panel__head') { h2 { 'Related' } }
              dl(class: 'relations') do
                if parents.any?
                  dt { 'Started by' }
                  parents.each do |machine, list|
                    dd do
                      reactor_link(machine.group_id)
                      span(class: 'muted') { " on #{list.join(', ')}" }
                    end
                  end
                end
                if children.any?
                  dt { 'Starts' }
                  children.each do |child|
                    dd do
                      reactor_link(child[:id])
                      span(class: 'muted') { " (#{child[:kind]})" }
                    end
                  end
                end
                if mounts.any?
                  dt { 'Mounts' }
                  mounts.each { |name| dd { code(title: name) { name.delete_prefix("#{@reactor.name}::") } } }
                end
              end
            end
          end

          def reactor_link(group_id)
            if (reactor = @reactors.find { it.group_id == group_id })
              a(href: reactor_href(group_id), title: group_id) { reactor.group_label }
            else
              code { group_id }
            end
          end

          def machines = @reactors.select { Module === it && it <= Sourced::Machine }

          # ---- Commands ----

          # The command's label, or its type within the machine where the
          # label is shared (targets.x.select).
          def command_name(transition)
            label = if @shared_labels.include?(transition[:label])
                      transition[:event].delete_prefix("#{@reactor.message_prefix}.")
                    else
                      transition[:label]
                    end
            code(class: "cmd cmd--#{transition[:kind]}", title: transition[:event]) do
              transition[:kind] == 'event' ? "on #{label}" : label
            end
          end

          # Where a transition leads: its targets, whether it may stay, the
          # machines it starts.
          def outcome(transition)
            targets = transition[:targets]
            text = targets.any? ? "→ #{targets.join(' | ')}" : 'stays'
            text += ' | stays' if transition[:optional] && targets.any?
            text += ", starts #{transition[:starts].join(', ')}" if transition[:starts].any?
            text
          end

          # ---- Links ----

          def reactor_href(group_id) = helpers.url("/reactors/#{Rack::Utils.escape_path(group_id)}")
          def base_href = reactor_href(@reactor.group_id)
          def state_href(row) = "#{base_href}/states/#{MachineChart.dom_id(row.path)}"

          # Fetched over Datastar, which patches the page in, instead of loaded.
          def travel(href) = { 'on:click__prevent' => "@get(#{href.to_json})" }
        end
      end
    end
  end
end

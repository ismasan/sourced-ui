# frozen_string_literal: true

require 'sourced/ui/components'

module Sourced
  module UI
    module Dashboard
      module Components
        # The column beside the full screen map (TopologyMapPage) that a click
        # on a box fills: for a reactor, its own diagram (its statechart, if
        # it's a machine, else its event model) and what it handles, takes and
        # sends; for a namespace, its reactors, each opening its own.
        #
        # Patched in by id, over the empty one the page starts with.
        class ReactorPanel < Component
          ID = 'reactor-panel'

          # The empty panel, hidden until a box is picked.
          def self.empty = new(boundaries: nil, group_id: nil)

          # @param boundaries [Sourced::UI::Boundaries, nil]
          # @param group_id [String, nil] a reactor's, or a namespace's (Boundaries::Group)
          # @param topology [Array<#to_h>] Sourced.topology's nodes, for a reactor's event model
          # @param reactors [Array<Class>] the registered reactors
          def initialize(boundaries:, group_id:, topology: [], reactors: [])
            @boundaries = boundaries
            @group_id = group_id
            @topology = topology.map(&:to_h)
            @reactors = reactors
            @entry = boundaries && (boundaries.reactor(group_id) || boundaries.grouped.reactor(group_id))
          end

          def view_template
            aside(id: ID, class: 'reactor-panel', style: ('display: none' unless @entry),
                  data: { show: "$selected != ''" }, aria: { label: 'Selected reactor' }) do
              next unless @entry

              Boundaries::Group === @entry ? render_namespace : render_reactor
            end
          end

          private

          # ---- A reactor ----

          def render_reactor
            klass = @entry.reactor
            kind = kind_of(klass)
            render_head(@entry.label, kind, klass && reactor_href(@entry.group_id))
            p(class: 'reactor-panel__id') { code { @entry.group_id } }

            if klass && kind == 'machine'
              render_statechart(klass)
              render_machine_messages(klass)
              render_dispatches('Dispatches, by state', 'state', machine_dispatches(klass))
            else
              render_event_model
              render_messages(klass)
              render_dispatches('Dispatches, by what it reacts to', 'reaction', reaction_dispatches)
            end
            render_events_taken
          end

          def render_head(title, kind, page_href)
            header(class: 'reactor-panel__head') do
              span(class: "kind-badge kind-badge--#{kind}") { kind }
              h2 { title }
              div(class: 'reactor-panel__actions') do
                a(href: page_href, class: 'reactor-panel__open') { 'Open page →' } if page_href
                button(type: 'button', class: 'reactor-panel__close', aria: { label: 'Close' }, title: 'Close (Esc)',
                       data: { 'on:click' => "$selected = ''" }) { '×' }
              end
            end
          end

          def render_statechart(machine)
            figure(class: 'reactor-panel__chart') do
              render Sourced::UI::Components::Statechart.new(machine.to_h, title: "#{@entry.label} statechart", href:,
                                                                           command_href:)
            end
          end

          def render_event_model
            flow = EventFlow.build(@topology, @entry.group_id)
            return if flow.empty?

            figure(class: 'reactor-panel__chart reactor-panel__chart--plain') do
              render Sourced::UI::Components::EventModel.new(flow, href:, title: "#{@entry.label} event model")
            end
          end

          # A machine's commands, and the events it takes, each with the states
          # it leads to.
          def render_machine_messages(machine)
            commands, events = MachineChart.commands(machine.to_h).partition { it[:kind] == 'command' }
            section(class: 'reactor-panel__section') do
              h3 { "Commands (#{commands.size})" }
              message_list(commands.map { [it[:label], it[:event], :command, leads_to(it)] })
            end
            return if events.empty?

            section(class: 'reactor-panel__section') do
              h3 { "Events it takes (#{events.size})" }
              message_list(events.map { [it[:label], it[:event], :event, leads_to(it)] })
            end
          end

          def leads_to(transition)
            targets = transition[:targets].compact
            text = targets.any? ? "→ #{targets.join(' | ')}" : nil
            text = [text, "starts #{transition[:starts].join(', ')}"].compact.join(', ') if transition[:starts].any?
            text
          end

          # Another reactor's commands, with the events each decides, and the
          # events it takes.
          def render_messages(klass)
            handled = klass ? Array(klass.handled_messages) : []
            commands, events = handled.partition { Module === it && it <= Sourced::Command }
            produces = @topology.select { it[:type] == 'command' }.to_h { [it[:id], it[:produces]] }
            names = @topology.select { it[:type] in 'command' | 'event' }.to_h { [it[:id], it[:name]] }

            section(class: 'reactor-panel__section') do
              h3 { "Commands (#{commands.size})" }
              message_list(commands.map do |command|
                decided = Array(produces[command.type]).map { short(names[it] || it) }
                [short(command.name), command.type, :command, decided.any? ? "→ #{decided.join(', ')}" : nil]
              end)
            end
            section(class: 'reactor-panel__section') do
              h3 { "Events it takes (#{events.size})" }
              from = @boundaries.crossings.select { it.to == @entry.group_id }.to_h { [it.message, it.from] }
              message_list(events.map do |event|
                source = from[event.type]
                [short(event.name), event.type, :event, source && "from #{label_of(source)}"]
              end)
            end
          end

          # ---- What it dispatches ----

          # A dispatched message: its +text+, and its +type+ and +kind+ if it's
          # a message (a child started isn't), and +to+, the reactor that
          # handles it when that's another.
          Item = Data.define(:text, :type, :kind, :to)

          # [[heading, [[trigger, [Item]]]]], a heading for each group (a
          # state, or a reaction) and what each trigger in it dispatches.
          def render_dispatches(title, noun, groups)
            groups = groups.reject { |_, triggers| triggers.empty? }
            return if groups.empty?

            section(class: 'reactor-panel__section') do
              h3 { "#{title} (#{groups.size} #{noun}#{'s' unless groups.size == 1})" }
              div(class: 'reactor-panel__groups') do
                groups.each do |heading, triggers|
                  div(class: 'reactor-panel__group') do
                    code(class: 'reactor-panel__group-name') { heading }
                    dl(class: 'reactor-panel__triggers') do
                      triggers.each do |trigger, items|
                        dt { trigger }
                        dd { items.each { render_item(it) } }
                      end
                    end
                  end
                end
              end
            end
          end

          def render_item(item)
            div(class: 'reactor-panel__item') do
              if item.type
                span(class: "bm-message bm-message--#{item.kind}", title: item.type) { item.text }
              else
                span(class: 'reactor-panel__starts') { item.text }
              end
              span(class: 'muted') { " → #{label_of(item.to)}" } if item.to
            end
          end

          # Each state that dispatches anything, depth first: what it does on
          # entry, after its timers, and on exit, and the children it starts
          # and stops, on entering, on leaving, or with a command.
          def machine_dispatches(machine)
            definition = machine.to_h
            labels = MachineChart.command_labels(definition)
            MachineChart.each_node(definition).map do |node|
              triggers = Hash.new { |h, k| h[k] = [] }
              node[:entry].each { |action| triggers['on entry'].concat(messages(action[:dispatches], labels)) }
              node[:invoke].each { triggers['on entry'] << child('starts', it[:id]) }
              node[:stops].each { triggers['on entry'] << child('stops', it) }
              node[:after].each do |timer|
                delay = MachineChart.delay_label(MachineChart.timer_delay(timer))
                triggers["after #{delay}"].concat(messages(timer[:dispatches], labels))
              end
              node[:exit].each { |action| triggers['on exit'].concat(messages(action[:dispatches], labels)) }
              node[:invoke].each { triggers['on exit'] << child('stops', it[:id]) }
              node[:on].each_value do |transition|
                transition[:starts].each { triggers["on #{transition[:label]}"] << child('starts', it) }
              end
              [node[:id], triggers.map { |trigger, items| [trigger, items.uniq] }]
            end
          end

          # Each of its reactions and what it dispatches: its automations, by
          # the message each reacts to, what they dispatch by the reactor
          # that takes it, said once.
          def reaction_dispatches
            @topology.select { it[:type] == 'automation' && it[:group_id] == @entry.group_id }.map do |automation|
              on = automation[:name].to_s[/\Areaction\((.+)\)\z/, 1] || automation[:name].to_s
              by_target = messages(automation[:produces], {}).group_by(&:to).map do |to, items|
                ["to #{to ? label_of(to) : 'itself'}", items.map { it.with(to: nil) }]
              end
              ["on #{short(on)}", by_target]
            end
          end

          def messages(types, labels)
            Array(types).map do |type|
              Item.new(text: labels[type] || short(name_of(type)), type:, kind: message_kind(type), to: handler_of(type))
            end
          end

          def child(verb, group_id) = Item.new(text: "#{verb} #{label_of(group_id)}", type: nil, kind: nil, to: nil)

          # The reactor that handles a command, when it's another one.
          def handler_of(type)
            @handlers ||= MachineChart.command_handlers(@reactors)
            handler = @handlers[type]
            handler unless handler == @entry.group_id
          end

          def name_of(type) = topology_names[type] || Sourced::Message.registry[type]&.name || type

          def message_kind(type)
            node = @topology.find { it[:id] == type }
            return node[:type].to_sym if node && (node[:type] in 'command' | 'event')

            klass = Sourced::Message.registry[type]
            klass && klass < Sourced::Command ? :command : :event
          end

          def topology_names = @topology_names ||= @topology.select { it[:type] in 'command' | 'event' }.to_h { [it[:id], it[:name]] }

          # ---- Its events, elsewhere ----

          RELATIONS = { reacts: 'reacted to', projects: 'projected', evolves: 'evolved from', starts: 'started' }.freeze

          # The reactors that take its events: a line each, saying how and how
          # many, the events themselves in its tooltip.
          def render_events_taken
            taken = @boundaries.crossings.select { it.from == @entry.group_id && it.to && it.kind == :event }.group_by(&:to)
            return if taken.empty?

            section(class: 'reactor-panel__section') do
              h3 { "Its events are taken by #{taken.size} reactor#{'s' unless taken.size == 1}" }
              ul(class: 'reactor-panel__messages reactor-panel__takers') do
                taken.sort_by { |to, _| label_of(to) }.each do |to, crossings|
                  events = crossings.map(&:name).uniq
                  li(title: events.map { short(it) }.join("\n")) do
                    span(class: 'reactor-panel__taker') { label_of(to) }
                    span(class: 'muted') do
                      how = crossings.map { RELATIONS.fetch(it.relation, it.relation.to_s) }.uniq.join(', ')
                      " #{how}, #{events.size} event#{'s' unless events.size == 1}"
                    end
                  end
                end
              end
            end
          end

          # [name, type, kind, note] rows.
          def message_list(rows)
            return p(class: 'muted reactor-panel__none') { 'None.' } if rows.empty?

            ul(class: 'reactor-panel__messages') do
              rows.each do |name, type, kind, note|
                li do
                  span(class: "bm-message bm-message--#{kind}", title: type) { name }
                  span(class: 'muted') { " #{note}" } if note
                end
              end
            end
          end

          # ---- A namespace ----

          def render_namespace
            render_head(@entry.label, 'namespace', nil)
            p(class: 'reactor-panel__id') { code { @entry.group_id } }
            p(class: 'muted') do
              plain "#{@entry.members.size} reactors, with #{@entry.inside} crossings between them. Pick one to see it."
            end
            ul(class: 'topology__isolated reactor-panel__members') do
              @entry.members.each do |member|
                kind = kind_of(member.reactor)
                li do
                  button(type: 'button', class: "reactor-pill reactor-pill--#{kind}", title: member.group_id,
                         data: { 'on:click' => self.class.pick(helpers, member.group_id) }) do
                    span(class: 'reactor-pill__name') { member.label }
                    span(class: 'reactor-pill__kind') { kind }
                  end
                end
              end
            end
          end

          # The Datastar expression that picks +group_id+: the panel's request.
          def self.pick(helpers, group_id)
            "$selected = #{group_id.to_json}; @get(#{helpers.url("/topology/map/panel?id=#{Rack::Utils.escape(group_id)}").to_json})"
          end

          # ---- Helpers ----

          def kind_of(klass)
            return 'reactor' unless Module === klass

            Boundaries::KINDS.find { |base, _| klass <= base }&.last || 'reactor'
          end

          def short(name) = name.to_s.split('::').last(2).join('::')

          def label_of(group_id) = @boundaries.reactor(group_id)&.label || group_id

          def reactor_href(group_id) = helpers.url("/reactors/#{Rack::Utils.escape_path(group_id)}")

          def href = ->(group_id) { reactor_href(group_id) if @reactors.any? { it.group_id == group_id } }

          # A command an action dispatches, linked to the page of the reactor
          # that handles it, as on the reactor's page.
          def command_href
            handlers = MachineChart.command_handlers(@reactors)
            lambda do |type|
              group_id = handlers[type]
              reactor_href(group_id) if group_id && group_id != @entry.group_id
            end
          end
        end
      end
    end
  end
end

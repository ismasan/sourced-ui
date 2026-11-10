# frozen_string_literal: true

require 'rack'
require 'rack/static'
require 'logger'
require 'datastar'
require 'sidereal'
require 'sourced/ui/dashboard/components'
require 'sourced/ui/dashboard/components/modal'
require 'sourced/ui/dashboard/components/system_page'
require 'sourced/ui/dashboard/components/message_page'
require 'sourced/ui/dashboard/components/events_tree'
require 'sourced/ui/dashboard/components/topology_page'
require 'sourced/ui/dashboard/components/offsets_page'
require 'sourced/ui/dashboard/components/reactor_page'
require 'sourced/ui/dashboard/components/machine_instance_page'

module Sourced
  module UI
    module Dashboard
      ASSETS_DIR = File.expand_path("#{File.dirname(__FILE__)}/assets")
      HEADER_RULES = if ENV['SOURCED_UI_TESTING']
        [[:all, {"cache-control" => "no-cache, no-store, must-revalidate"}]].freeze
      else
        [[:all, {"cache-control" => "private, max-age=86400"}]].freeze
      end

      # Consumer-group operations are the operator commands of
      # Sourced::ConsumerGroupMachine, exposed to the browser via
      # `POST /commands`. The cards render only those a group's status
      # accepts; a click on a card a moment stale is refused with a 409.
      class Service < Sidereal::App
        session secret: ENV.fetch('SOURCED_DASHBOARD_SESSION_SECRET') { 'x' * 64 }

        handle ConsumerGroupMachine::Start do |cmd|
          refusing_invalid_transitions { Sourced.start_consumer_group(cmd.payload.group_id) }
        end

        handle ConsumerGroupMachine::Stop do |cmd|
          refusing_invalid_transitions { Sourced.stop_consumer_group(cmd.payload.group_id, cmd.payload.message) }
        end

        handle ConsumerGroupMachine::Reset do |cmd|
          refusing_invalid_transitions { Sourced.reset_consumer_group(cmd.payload.group_id) }
        end

        get '/' do
          messages = store.read_all(limit: per_page, order: :desc)
          component(Components::SystemPage.new(
            stats: store.stats,
            registered: registered_groups,
            messages:
          ))
        end

        get '/updates' do
          stats = store.stats
          datastar.stream do |sse|
            while true
              sleep 1
              messages = store.read_all(limit: per_page, order: :desc)
              sse.patch_elements Components::MessageList.recent(messages:)
            end
          end

          datastar.stream do |sse|
            while true
              sleep 0.1
              new_stats = store.stats
              next unless stats != new_stats

              stats = new_stats
              sse.patch_elements Components::SystemPage::Consumers.new(stats:, registered: registered_groups)
            end
          end
        end

        post '/log/filters/add' do
          filters = parse_filter_params(request.params)
          add_filter = request.params['add_filter']
          if add_filter
            filters << { type: add_filter, attributes: {} }
          end
          datastar.stream do |sse|
            sse.patch_elements Sourced::UI::Components::MessageFilter.new(
              filters: filters,
              action: url('/log/filters/add'),
              submit: url('/log')
            )
          end
        end

        get '/log/:position' do |position:|
          position = position.to_i
          page_start = ((position - 1) / per_page) * per_page + 1
          messages = store.read_all(from_position: page_start, limit: per_page)

          if datastar.sse?
            datastar.stream do |sse|
              sse.execute_script <<-JS
                history.replaceState({}, '', '#{request.path}');
              JS
              sse.patch_elements Components::MessagePage.new(
                position:,
                messages:,
                layout: false
              )
            end
          else
            component Components::MessagePage.new(position:, messages:)
          end
        end

        get '/log' do
          from = (request.params['from'] || 1).to_i
          filters = parse_filter_params(request.params)
          conditions = filters_to_conditions(filters)
          messages = store.read_all(from_position: from, conditions: conditions, limit: per_page)
          component Components::MessagePage.new(position: from, messages:, filters: filters)
        end

        get '/log/more' do
          from = datastar.signals['offset'].to_i + 1
          messages = store.read_all(from_position: from, limit: per_page)
          if from < messages.last_position
            datastar.stream do |sse|
              sse.patch_signals(offset: messages.messages.last.position)
              messages.each do |m|
                sse.patch_elements(
                  Components::MessageRow.new(m, href: "/log/#{m.position}"),
                  selector: '#messages-page',
                  mode: 'append'
                )
              end
            end
          else
            status 204
          end
        end

        get '/events/:event_id/correlation' do |event_id:|
          events = Sourced.store.read_correlation_batch(event_id)
          datastar.stream do |sse|
            sse.patch_elements Components::Modal.new(
              title: 'Message correlation',
              content: Components::EventsTree.new(events:, event_id:)
            )
            sse.patch_signals modal: true
          end
        end

        get '/offsets' do
          from_id = request.params['from_id']&.to_i
          group_id = request.params['group_id']&.then { |v| v.empty? ? nil : v }
          groups = store.stats.groups
          result = store.read_offsets(limit: per_page, from_id: from_id, group_id: group_id)
          component(Components::OffsetsPage.new(result:, groups:, selected_group: group_id))
        end

        get '/topology' do
          component(Components::TopologyPage.new(topology: Sourced.topology.map(&:to_h)))
        end

        get '/reactors/:group_id' do |group_id:|
          render_reactor(group_id)
        end

        get '/reactors/:group_id/updates' do |group_id:|
          halt 404, 'Not found' unless store.stats.groups.any? { it[:group_id] == group_id }

          snapshot = nil
          datastar.stream do |sse|
            while true
              stats = store.stats
              group = stats.groups.find { it[:group_id] == group_id }
              if group && [group, stats.max_position] != snapshot
                snapshot = [group, stats.max_position]
                sse.patch_elements Components::SystemPage::GroupCard.new(group:, tip: stats.max_position, link: false)
                sse.patch_elements Components::SystemPage::FailureCard.new(group:)
              end
              sleep 0.1
            end
          end
        end

        get '/reactors/:group_id/states/:state' do |group_id:, state:|
          render_reactor(group_id, state)
        end

        # A machine instance, from its partition values in the query: at the
        # log position +at+, or at the latest.
        get '/reactors/:group_id/instance' do |group_id:|
          render_instance(find_machine(group_id))
        end

        # The instance at the latest, patched in as messages after +after+
        # arrive in its partition.
        get '/reactors/:group_id/instance/updates' do |group_id:|
          machine = find_machine(group_id)
          values = partition_values(machine)
          types = MachineTimeline.message_types(machine)
          last = request.params['after'].to_i

          datastar.stream do |sse|
            while true
              sleep 0.5
              next if store.read_partition(values, handled_types: types, after_position: last).messages.empty?

              timeline = MachineTimeline.load(machine, values, store:)
              last = timeline.last_position
              sse.patch_elements Components::MachineInstance.new(reactor: machine, reactors: Sourced.router.reactors, timeline:)
            end
          end
        end

        private

        # A Datastar request (a message picked in the instance's feed) gets
        # the page patched in place, and its URL pushed: the partition values
        # and +at+ alone, not Datastar's own params.
        def render_instance(machine)
          values = partition_values(machine)
          at = request.params['at']&.then { Integer(it, exception: false) }&.clamp(0..)
          page = Components::MachineInstancePage.new(
            reactor: machine,
            reactors: Sourced.router.reactors,
            timeline: MachineTimeline.load(machine, values, store:),
            at:,
            layout: !datastar.sse?
          )
          return component(page) unless datastar.sse?

          # One patch, then closed: no heartbeat keeping it open.
          datastar.stream(heartbeat: false) do |sse|
            sse.patch_elements page
            sse.execute_script "history.pushState({}, '', #{page.href.to_json})"
          end
        end

        def find_machine(group_id)
          machine = Sourced.router.reactors.find { it.group_id == group_id }
          halt 404, 'Not found' unless Module === machine && machine <= Sourced::Machine
          machine
        end

        # A value for each of the machine's partition keys, from the query:
        # only those, so Datastar's own `datastar` param doesn't count.
        def partition_values(machine)
          values = Array(machine.partition_keys).to_h { |key| [key.to_sym, request.params[key.to_s].to_s.strip] }
          missing = values.select { _2.empty? }.keys
          halt 400, "Missing values for partition keys: #{missing.join(', ')}" if missing.any?
          values
        end

        # A Datastar request (a state picked on a machine's page) gets the
        # page patched in place, and its URL pushed onto the browser's
        # history; any other gets the whole page.
        def render_reactor(group_id, state = nil)
          page = Components::ReactorPage.build(
            group_id,
            reactors: Sourced.router.reactors,
            stats: store.stats,
            topology: -> { Sourced.topology },
            state:,
            layout: !datastar.sse?
          )
          halt 404, 'Not found' unless page
          return component(page) unless datastar.sse?

          path = request.path
          datastar.stream do |sse|
            sse.patch_elements page
            sse.execute_script "history.pushState({}, '', #{path.to_json})"
          end
        end

        def store
          Sourced.store
        end

        # 204 once the group has moved; 409 when its status has moved on
        # since the card was rendered and no longer accepts the command.
        def refusing_invalid_transitions
          yield
          status 204
        rescue Sourced::Store::InvalidConsumerGroupTransitionError => e
          halt 409, e.message
        end

        # The group_ids of the reactors registered now. The store keeps the
        # offsets of any it has had, those whose classes have gone too.
        def registered_groups = Sourced.router.reactors.map(&:group_id)

        def per_page
          50
        end

        def parse_filter_params(params)
          (params['filters'] || {}).values.map { |f|
            { type: f['type'], attributes: f['attributes'] || {} }
          }
        end

        def filters_to_conditions(filters)
          parsed = Sourced::UI::Components::Types::Filters.parse(filters)
          parsed.flat_map { |entry|
            attrs = entry[:attributes].reject { |_, v| v.nil? || v.empty? }
            next [] if attrs.empty?
            entry[:type].to_conditions(**attrs.transform_keys(&:to_sym))
          }
        end
      end

      App = Rack::Builder.new do
        use Rack::Static, urls: ["/stylesheets", "/images", "/javascripts"],
          root: ASSETS_DIR,
          cascade: true,
          headers: HEADER_RULES

        run Service
      end
    end
  end
end

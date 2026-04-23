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

module Sourced
  module UI
    module Dashboard
      ASSETS_DIR = File.expand_path("#{File.dirname(__FILE__)}/assets")
      HEADER_RULES = if ENV['SOURCED_UI_TESTING']
        [[:all, {"cache-control" => "no-cache, no-store, must-revalidate"}]].freeze
      else
        [[:all, {"cache-control" => "private, max-age=86400"}]].freeze
      end

      # Consumer-group operations are exposed to the browser as typed
      # Sidereal messages, dispatched via `POST /commands`.
      ResumeConsumerGroup = Sidereal::Message.define('sourced.ui.resume_consumer_group') do
        attribute :group_id, Sidereal::Types::String.present
      end

      StopConsumerGroup = Sidereal::Message.define('sourced.ui.stop_consumer_group') do
        attribute :group_id, Sidereal::Types::String.present
      end

      ResetConsumerGroup = Sidereal::Message.define('sourced.ui.reset_consumer_group') do
        attribute :group_id, Sidereal::Types::String.present
      end

      class Service < Sidereal::App
        session secret: ENV.fetch('SOURCED_DASHBOARD_SESSION_SECRET') { 'x' * 64 }

        handle ResumeConsumerGroup do |cmd|
          Sourced.start_consumer_group(cmd.payload.group_id)
          status 204
        end

        handle StopConsumerGroup do |cmd|
          Sourced.stop_consumer_group(cmd.payload.group_id)
          status 204
        end

        handle ResetConsumerGroup do |cmd|
          Sourced.reset_consumer_group(cmd.payload.group_id)
          status 204
        end

        get '/' do
          messages = store.read_all(limit: per_page, order: :desc)
          component(Components::SystemPage.new(
            stats: store.stats,
            messages:
          ))
        end

        get '/updates' do
          Console.warn "EEEEAAA #{url('/uno')} #{request.script_name}"
          stats = store.stats
          datastar.stream do |sse|
            Console.warn "EEEEAAA #{url('/dos')} #{request.script_name}"
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

              Console.warn "EEEEAAA #{url('/dos')}"
              stats = new_stats
              sse.patch_elements Components::SystemPage::Consumers.new(stats:)
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

        private

        def store
          Sourced.store
        end

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

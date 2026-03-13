# frozen_string_literal: true

require 'rack'
require 'logger'
require 'rack/static'
require 'sourced/ccc'
require 'datastar'
require 'sourced/ui/dashboard/components'
require 'sourced/ui/dashboard/components/modal'
require 'sourced/ui/dashboard/components/system_page'
require 'sourced/ui/dashboard/components/message_page'
require 'sourced/ui/dashboard/components/events_tree'
require 'sourced/ui/dashboard/components/topology_page'

module Sourced
  module UI
    module Dashboard
      ASSETS_DIR = File.expand_path("#{File.dirname(__FILE__)}/assets")
      HEADER_RULES = if ENV['SOURCED_UI_TESTING']
        [[:all, {"cache-control" => "no-cache, no-store, must-revalidate"}]].freeze
      else
        [[:all, {"cache-control" => "private, max-age=86400"}]].freeze
      end

      class Router
        def self.call(env)
          request = Rack::Request.new(env)
          new(request:).run
        end

        attr_reader :request

        def initialize(request:)
          @request = request
        end

        def run
          path = request.path_info
          path = '/' if path.empty?

          case path
            when '/'
              store = Sourced::CCC.store
              messages = store.read_all(limit: 20, order: :desc)
              phlex(Components::SystemPage.new(
                stats: store.stats,
                messages:
              ))
            when '/updates'
              store = Sourced::CCC.store
              stats = store.stats
              datastar.stream do |sse|
                while true
                  sleep 1
                  messages = store.read_all(limit: 20, order: :desc)
                  sse.patch_elements Components::SystemPage::Messages.new(messages:)
                end
              end
              datastar.stream do |sse|
                while true
                  sleep 0.1
                  new_stats = store.stats
                  next unless stats != new_stats

                  stats = new_stats
                  sse.patch_elements Components::SystemPage::Consumers.new(stats:)
                end
              end
            when '/consumer-groups/resume' # POST
              group_id = request.params['group_id']
              Sourced::CCC.store.start_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/consumer-groups/stop' # POST
              group_id = request.params['group_id']
              Sourced::CCC.store.stop_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/consumer-groups/reset' # POST
              group_id = request.params['group_id']
              Sourced::CCC.store.reset_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when /\/log\/(\d+)$/ # /log/42
              position = Regexp.last_match(1).to_i
              store = Sourced::CCC.store
              # Fetch a window of messages around the requested position
              messages = store.read_all(from_position: position, limit: 50, order: :desc)

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
                phlex Components::MessagePage.new(position:, messages:)
              end
            when '/log' # /log or /log?from=N
              from = (request.params['from'] || 0).to_i
              store = Sourced::CCC.store
              messages = store.read_all(from_position: from, limit: 50, order: :desc)
              phlex Components::MessagePage.new(messages:)
            when /\/events\/([^\/]*)\/correlation$/ # /events/uuid/correlation
              event_id = Regexp.last_match(1)

              events = Sourced::CCC.store.read_correlation_batch(event_id)
              datastar.stream do |sse|
                sse.patch_elements Components::Modal.new(
                  title: 'Message correlation',
                  content: Components::EventsTree.new(events:, event_id:)
                )
                sse.patch_signals modal: true
              end
            when '/topology'
              phlex(Components::TopologyPage.new(topology: Sourced::CCC.topology.map(&:to_h)))
            else
              [404, {'Content-Type' => 'text/html'}, ["<h1>404 Not Found</h1><p>The page you requested does not exist.</p>"]]
          end
        end

        def phlex(component, status: 200)
          [status, {'Content-Type' => 'text/html'}, [component.render_in(view_context)]]
        end

        def datastar
          @datastar ||= (
            Datastar.from_rack_env(request.env, view_context:)
          )
        end

        def view_context
          @view_context ||= Components::Component::Helpers.new(request:)
        end
      end

      App = Rack::Builder.new do
        use Rack::Static, urls: ["/stylesheets", "/images", "/javascripts"],
          root: ASSETS_DIR,
          cascade: true,
          headers: HEADER_RULES

        run Router
      end
    end
  end
end

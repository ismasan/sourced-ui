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

          store = CCC.store
          per_page = 50

          case path
            when '/'
              store = Sourced::CCC.store
              messages = store.read_all(limit: per_page, order: :desc)
              phlex(Components::SystemPage.new(
                stats: store.stats,
                messages:
              ))
            when '/updates'
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
                  sse.patch_elements Components::SystemPage::Consumers.new(stats:)
                end
              end
            when '/consumer-groups/resume' # POST
              group_id = request.params['group_id']
              Sourced::CCC.start_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/consumer-groups/stop' # POST
              group_id = request.params['group_id']
              Sourced::CCC.stop_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/consumer-groups/reset' # POST
              group_id = request.params['group_id']
              Sourced::CCC.reset_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when /\/log\/(\d+)$/ # /log/42
              position = Regexp.last_match(1).to_i
              # Fetch the 50-item page that contains the requested position
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
                phlex Components::MessagePage.new(position:, messages:)
              end
            when '/log'
              from = (request.params['from'] || 1).to_i
              messages = store.read_all(from_position: from, limit: per_page)
              phlex Components::MessagePage.new(position: from, messages:)

            when '/log/more'
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
                [204, {}, []]
              end

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
            when '/offsets'
              from_id = request.params['from_id']&.to_i
              group_id = request.params['group_id']&.then { |v| v.empty? ? nil : v }
              groups = store.stats.groups
              result = store.read_offsets(limit: per_page, from_id: from_id, group_id: group_id)
              phlex(Components::OffsetsPage.new(result:, groups:, selected_group: group_id))
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

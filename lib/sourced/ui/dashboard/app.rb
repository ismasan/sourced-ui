# frozen_string_literal: true

require 'rack'
require 'logger'
require 'rack/static'
require 'sourced'
require 'datastar'
require 'sourced/ui/dashboard/components'
require 'sourced/ui/dashboard/components/system_page'

module Sourced
  module UI
    module Dashboard
      ASSETS_DIR = File.expand_path("#{File.dirname(__FILE__)}/assets")
      HEADER_RULES = if ENV['SOURCED_UI_TESTING']
        [[:all, {"cache-control" => "no-cache, no-store, must-revalidate"}]].freeze
        # [].freeze
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
          case request.path
            when '/'
              phlex(Components::SystemPage.new(stats: Sourced.config.backend.stats))
            when '/updates'
              stats = Sourced.config.backend.stats
              datastar.stream do |sse|
                while true
                  sleep 0.1
                  new_stats = Sourced.config.backend.stats
                  # Only stream updates to the UI if stats changed
                  next unless stats != new_stats

                  stats = new_stats
                  sse.merge_fragments Components::SystemPage::Consumers.new(stats:)
                end
              end
            when '/consumer-groups/resume' # POST
              group_id = datastar.signals['group_id']
              Sourced.config.backend.start_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/consumer-groups/stop' # POST
              group_id = datastar.signals['group_id']
              Sourced.config.backend.stop_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/consumer-groups/reset' # POST
              group_id = datastar.signals['group_id']
              Sourced.config.backend.reset_consumer_group(group_id)

              [204, {'Content-Type' => 'text/html'}, []]
            when '/reactors'
              [200, {'Content-Type' => 'text/html'}, ["<h1>Reactors page!</h1>"]]
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

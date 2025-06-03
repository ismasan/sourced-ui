# frozen_string_literal: true

require 'rack'
require 'rack/static'
require 'sourced/ui/dashboard/layout'

module Sourced
  module UI
    module Dashboard
      ASSETS_DIR = File.expand_path("#{File.dirname(__FILE__)}/assets")
      HEADER_RULES = if ENV['SOURCED_UI_TESTING']
        # [[:all, {"cache-control" => "no-cache, no-store, must-revalidate"}]].freeze
        [].freeze
      else
        [[:all, {"cache-control" => "private, max-age=86400"}]].freeze
      end

      class Router
        def call(env)
          request = Rack::Request.new(env)
          case request.path
            when '/'
              [200, {'Content-Type' => 'text/html'}, [Layout.new.call(context: {request:})]]
            when '/reactors'
              [200, {'Content-Type' => 'text/html'}, ["<h1>Reactors page!</h1>"]]
            else
              [404, {'Content-Type' => 'text/html'}, ["<h1>404 Not Found</h1><p>The page you requested does not exist.</p>"]]
          end
        end
      end

      App = Rack::Builder.new do
        use Rack::Static, urls: ["/stylesheets", "/images", "/javascripts"],
          root: ASSETS_DIR,
          cascade: true,
          headers: HEADER_RULES

        # map '/' do
        run Router.new
        # end
      end
    end
  end
end

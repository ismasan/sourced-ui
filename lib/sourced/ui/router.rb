# frozen_string_literal: true

require 'rack'
require 'rack/session/cookie'

module Sourced
  module UI
    # A minimal Rack-compatible router with a Sinatra-style DSL.
    #
    # Subclass and define routes with {.get}, {.post}, {.put}, {.patch}, {.delete},
    # or {.redirect}. Route blocks are evaluated in the context of a router instance,
    # so they have access to {#request} and any instance methods defined on the subclass.
    #
    # Named parameters in paths (e.g. +:id+) are extracted and passed to the block
    # as keyword arguments. Trailing slashes are handled automatically — +/items+ and
    # +/items/+ match the same route.
    #
    # Unmatched requests return +404+.
    #
    # @example Basic subclass with routes
    #   class MyApp < Sourced::UI::Router
    #     get '/' do
    #       [200, { 'Content-Type' => 'text/plain' }, ['hello']]
    #     end
    #
    #     get '/items/:id' do |id:|
    #       [200, { 'Content-Type' => 'text/plain' }, ["item #{id}"]]
    #     end
    #
    #     post '/items' do
    #       [201, { 'Content-Type' => 'text/plain' }, ['created']]
    #     end
    #
    #     redirect '/legacy', '/items'
    #   end
    #
    # @example Callable handler objects
    #   # Any object (or lambda) that responds to #call(request, params)
    #   # can be passed as a handler instead of a block. Useful for
    #   # extracting route logic into standalone, testable objects.
    #
    #   class ShowItem
    #     def call(request, params)
    #       id = params[:id]
    #       [200, { 'Content-Type' => 'text/plain' }, ["item #{id}"]]
    #     end
    #   end
    #
    #   class MyApp < Sourced::UI::Router
    #     get '/items/:id', ShowItem.new
    #
    #     # Lambdas work too
    #     get '/health', ->(req, params) { [200, {}, ['ok']] }
    #   end
    #
    # @example Mounting as a Rack app
    #   # config.ru
    #   run MyApp
    #
    # @example Using with Rack::Builder
    #   app = Rack::Builder.new do
    #     use Rack::Static, urls: ['/assets'], root: 'public'
    #     run MyApp
    #   end
    class Router
      GET = 'GET'
      POST = 'POST'
      DELETE = 'DELETE'
      PATCH = 'PATCH'
      PUT = 'PUT'

      class << self
        # Returns the registered routes, keyed by HTTP method.
        #
        # Each entry is an array of +[pattern, path, handler]+ tuples where
        # +pattern+ is a compiled Regexp, +path+ is the original string,
        # and +handler+ is a Proc or +[:redirect, target]+.
        #
        # @return [Hash{String => Array}]
        def routes
          @routes ||= {
            GET => [],
            POST => [],
            DELETE => [],
            PATCH => [],
            PUT => []
          }
        end

        # Register a GET route.
        #
        # @param path [String] URL pattern, may include named params (e.g. +/items/:id+)
        # @param handler [#call, nil] callable handler; if omitted, a block is expected
        # @yield Block evaluated in the router instance context when the route matches
        # @yieldparam kwargs [Symbol => String] named parameters extracted from the path
        # @return [self]
        #
        # @example Static path
        #   get '/health' do
        #     [200, {}, ['ok']]
        #   end
        #
        # @example With named parameters
        #   get '/users/:user_id/posts/:id' do |user_id:, id:|
        #     [200, {}, ["user=#{user_id} post=#{id}"]]
        #   end
        def get(path, handler = nil, &h)
          add GET, path, handler, &h
        end

        # Register a POST route.
        #
        # @param path [String] URL pattern
        # @param handler [#call, nil] callable handler
        # @yield (see .get)
        # @yieldparam kwargs (see .get)
        # @return [self]
        def post(path, handler = nil, &h)
          add POST, path, handler, &h
        end

        # Register a PUT route.
        #
        # @param path [String] URL pattern
        # @param handler [#call, nil] callable handler
        # @yield (see .get)
        # @yieldparam kwargs (see .get)
        # @return [self]
        def put(path, handler = nil, &h)
          add PUT, path, handler, &h
        end

        # Register a PATCH route.
        #
        # @param path [String] URL pattern
        # @param handler [#call, nil] callable handler
        # @yield (see .get)
        # @yieldparam kwargs (see .get)
        # @return [self]
        def patch(path, handler = nil, &h)
          add PATCH, path, handler, &h
        end

        # Register a DELETE route.
        #
        # @param path [String] URL pattern
        # @param handler [#call, nil] callable handler
        # @yield (see .get)
        # @yieldparam kwargs (see .get)
        # @return [self]
        def delete(path, handler = nil, &h)
          add DELETE, path, handler, &h
        end

        # Register a GET redirect from one path to another.
        #
        # Returns a +301 Moved Permanently+ with the +Location+ header set.
        #
        # @param from [String] source URL pattern
        # @param to [String] target URL
        # @return [self]
        #
        # @example
        #   redirect '/old-path', '/new-path'
        def redirect(from, to)
          get from do
            [301, {'Location' => to }, []]
          end
        end

        # Configure signed cookie sessions for this router.
        #
        # Wraps the router in +Rack::Session::Cookie+ middleware with HMAC signing.
        # Once enabled, route handlers can access the session via {#session}.
        #
        # @param secret [String] HMAC signing secret (required, must be >= 64 bytes
        #   for security; +Rack::Session::Cookie+ enforces a 16-byte minimum)
        # @param opts [Hash] additional options forwarded to +Rack::Session::Cookie+
        # @option opts [String] :key cookie name (default: +"rack.session"+)
        # @option opts [String] :path cookie path (default: +"/"+)
        # @option opts [Boolean] :httponly (default: +true+)
        # @option opts [Symbol] :same_site +:lax+, +:strict+, or +:none+ (default: +:lax+)
        # @option opts [Integer] :expire_after seconds until cookie expires
        # @return [void]
        #
        # @example
        #   class MyApp < Sourced::UI::Router
        #     session secret: ENV.fetch('SESSION_SECRET')
        #
        #     get '/login' do
        #       session[:user_id] = 42
        #       [200, {}, ['logged in']]
        #     end
        #
        #     get '/profile' do
        #       [200, {}, ["user: #{session[:user_id]}"]]
        #     end
        #   end
        def session(secret:, **opts)
          session_options = { secret: }.merge(opts)
          self.app = Rack::Session::Cookie.new(app, **session_options)
          self
        end

        def app=(a)
          @app = a
        end

        def app
          @app ||= method(:route)
        end

        # Register a route.
        #
        # @param verb [String] HTTP method ('POST', 'GET', etc)
        # @param path [String] URL pattern
        # @param handler [#call, nil] callable handler
        # @yield (see .get)
        # @yieldparam kwargs (see .get)
        # @return [self]
        def add(verb, path, handler = nil, &h)
          handler ||= h
          routes[verb] << [compile(path), path, handler]
          self
        end

        # Rack-compatible call interface.
        #
        # When sessions are enabled via {.session}, wraps the router in
        # +Rack::Session::Cookie+ middleware. The middleware is built once
        # and cached for subsequent requests.
        #
        # @param env [Hash] Rack environment
        # @return [Array(Integer, Hash, Array)] Rack response triplet
        def call(env)
          app.call(env)
        end

        def route(env)
          req = Rack::Request.new(env)
          new(req).call
        end

        private

        # Compile a path pattern into a Regexp.
        #
        # Named segments like +:id+ become named capture groups.
        # An optional trailing slash is appended so both +/items+ and
        # +/items/+ match the same route.
        #
        # @param path [String] route pattern (e.g. +/items/:id+)
        # @return [Regexp] compiled pattern
        private def compile(path)
          pattern = path.gsub(/:([a-z_]+)/, '(?<\1>[^/]+)')
          Regexp.new("\\A#{pattern}/?\\z")
        end
      end

      # @return [Rack::Request] the current request
      attr_reader :request

      # @param request [Rack::Request]
      def initialize(request)
        @request = request
      end

      # Returns the session hash for the current request.
      #
      # Only available when sessions are enabled via {.session} on the
      # router subclass. Raises if sessions are not configured.
      #
      # @return [Rack::Session::Abstract::SessionHash] session data
      # @raise [RuntimeError] if sessions are not enabled
      #
      # @example Reading and writing session data
      #   post '/login' do
      #     session[:user_id] = request.params['user_id']
      #     [200, {}, ['ok']]
      #   end
      #
      #   get '/whoami' do
      #     [200, {}, ["user: #{session[:user_id]}"]]
      #   end
      def session
        request.env['rack.session'] || raise('Sessions not configured. Use `session secret: "..."` in your Router subclass.')
      end

      # Dispatch the request to a matching route handler.
      #
      # Returns +404+ if no route matches. For redirects, returns +301+ with a
      # +Location+ header. Matched path parameters are stored in
      # +request.env['router.params']+ as a symbol-keyed hash.
      #
      # When the handler is a block, it is evaluated via +instance_exec+
      # in the router instance context with named params as keyword arguments.
      # When the handler is a lambda or any other callable, it receives the
      # +Rack::Request+ and extracted params hash via +#call+.
      #
      # @return [Array(Integer, Hash, Array)] Rack response triplet
      def call
        handler, params = match(request.request_method, request.path_info)

        if handler.nil?
          return not_found
        end

        request.env['router.params'] = params

        if handler.is_a?(Proc) && !handler.lambda?
          instance_exec(**params, &handler)
        else
          handler.call(request, params)
        end
      end

      private def not_found
        [404, {'Content-Type' => 'text/html'}, ['Resource not found']]
      end

      # Find the first route matching the given HTTP method and path.
      #
      # @param method [String] HTTP method (e.g. +"GET"+)
      # @param path [String] request path
      # @return [Array(handler, Hash{Symbol => String}), nil] the handler and
      #   extracted named captures, or +nil+ if no route matches
      private def match(method, path)
        self.class.routes[method]&.each do |pattern, _, handler|
          if (m = pattern.match(path))
            return [handler, m.named_captures.transform_keys(&:to_sym)]
          end
        end
        nil
      end
    end
  end
end

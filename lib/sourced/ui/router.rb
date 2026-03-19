# frozen_string_literal: true

require 'rack'
require 'rack/session/cookie'

module Sourced
  module UI
    # A minimal Rack-compatible router with a Sinatra-style DSL and
    # trie-based dispatch.
    #
    # Routes are stored in a trie (prefix tree) keyed by path segment,
    # giving O(path segments) lookup regardless of the total number of
    # registered routes. Static segments are matched by exact hash lookup;
    # dynamic segments (+:param+) act as wildcard keys that capture the
    # corresponding path value.
    #
    # Subclass and define routes with {.get}, {.post}, {.put}, {.patch}, {.delete},
    # or {.redirect}. Route blocks are evaluated in the context of a router instance,
    # so they have access to {#request} and any instance methods defined on the subclass.
    #
    # Named parameters in paths (e.g. +:id+) are extracted and passed to the block
    # as keyword arguments. Trailing slashes are handled automatically — +/items+ and
    # +/items/+ match the same route. The root path (+/+) also matches an empty
    # +path_info+ for mounted sub-apps.
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

      # @api private
      # Strips leading or trailing slashes from a path string.
      NOSLASH = /\A\/|\/\z/

      # A dynamic path segment key in the route trie.
      # Holds the parameter name as a Symbol (e.g. +Param[:id]+).
      Param = Data.define(:name)

      # @api private
      # Matches a colon-prefixed segment and captures the name.
      PARAM_EXP = /\A:(.+)/

      # @api private
      # Sentinel appended to compiled segments — the empty-string leaf
      # key that stores the handler in the trie.
      LAST = [''].freeze

      class << self
        # Returns the route tries, keyed by HTTP method.
        #
        # Each value is a nested Hash (trie) where string keys are static
        # path segments, {Param} keys are dynamic segments, and the empty
        # string key (+""+ ) at a leaf holds the handler.
        #
        # @return [Hash{String => Hash}]
        def routes
          @routes ||= {
            GET => {},
            POST => {},
            DELETE => {},
            PATCH => {},
            PUT => {}
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

        # Set the Rack app used by {.call}.
        #
        # Typically set by {.session} to wrap the router in middleware.
        #
        # @param a [#call] a Rack-compatible app
        # @api private
        def app=(a)
          @app = a
        end

        # The Rack app dispatched by {.call}.
        #
        # Defaults to {.route}. When middleware (e.g. sessions) is added,
        # the middleware wraps this and becomes the new +app+.
        #
        # @return [#call]
        # @api private
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
          segments = compile(path)
          merge_route!(routes[verb], segments, handler)
          self
        end

        # Rack-compatible call interface.
        #
        # Delegates to {.app}, which is either {.route} directly or
        # a middleware chain (e.g. +Rack::Session::Cookie+) wrapping it.
        #
        # @param env [Hash] Rack environment
        # @return [Array(Integer, Hash, Array)] Rack response triplet
        def call(env)
          app.call(env)
        end

        # Inner Rack endpoint that performs route matching.
        #
        # Wraps the env in a +Rack::Request+ and delegates to {#call}.
        # This is the default {.app} and the target that middleware wraps.
        #
        # @param env [Hash] Rack environment
        # @return [Array(Integer, Hash, Array)] Rack response triplet
        # @api private
        def route(env)
          req = Rack::Request.new(env)
          new(req).call
        end

        private

        # Compile a path pattern into an array of trie keys.
        #
        # Strips leading/trailing slashes, splits on +/+, and converts
        # +:param+ segments into {Param} instances. An empty-string
        # sentinel ({LAST}) is appended as the leaf key.
        #
        # @param path [String] route pattern (e.g. +/items/:id+)
        # @return [Array<String, Param>] segment keys ending with +""+
        private def compile(path)
          path.gsub(NOSLASH, '').split('/').map do |segment|
            m = PARAM_EXP.match(segment)
            m ? Param.new(m[1].to_sym) : segment
          end + LAST
        end

        # Insert a route into the trie.
        #
        # Each segment becomes a key in a nested hash. Static segments
        # are plain strings; dynamic segments are {Param} instances.
        # The leaf key is always +""+  (from {LAST}) and its value is
        # the handler.
        #
        # @example Resulting trie for +get '/items/:id'+
        #   { "items" => { Param(:id) => { "" => handler } } }
        private def merge_route!(hash, list, handler)
          *keys, leaf_key = list
          target = keys.reduce(hash) { |h, k| h[k] ||= {} }
          target[leaf_key] = handler
          hash
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

      # Walk the trie to find a handler matching the given HTTP method and path.
      #
      # For each path segment the lookup tries an exact string match first
      # (O(1) hash lookup). If that fails, it checks for a {Param} wildcard
      # key and captures the segment value. This gives O(segments) dispatch
      # regardless of the total number of registered routes.
      #
      # @param method [String] HTTP method (e.g. +"GET"+)
      # @param path [String] request path
      # @return [Array(handler, Hash{Symbol => String}), nil] the handler and
      #   extracted params, or +nil+ if no route matches
      private def match(method, path)
        node = self.class.routes[method]
        return nil unless node

        segments = path.gsub(NOSLASH, '').split('/')
        params = {}

        segments.each do |segment|
          # Try exact match first
          child = node[segment]
          unless child
            # Fall back to a dynamic param key
            param_key = node.each_key.find { |k| k.is_a?(Param) }
            return nil unless param_key

            child = node[param_key]
            params[param_key.name] = segment
          end
          node = child
          return nil unless node.is_a?(Hash)
        end

        # The empty-string leaf (from LAST) holds the handler
        handler = node['']
        handler ? [handler, params] : nil
      end
    end
  end
end

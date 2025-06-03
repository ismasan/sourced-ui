# frozen_string_literal: true

require 'phlex'

module Sourced
  module UI
    module Dashboard
      module Components
        class Component < Phlex::HTML
          # Compatibility with Datastar
          def render_in(view_context)
            call(context: { view_context: })
          end

          private

          def helpers
            @helpers ||= context.fetch(:view_context)
          end

          class Helpers
            HTTP_X_FORWARDED_HOST = 'HTTP_X_FORWARDED_HOST'.freeze

            def initialize(request:)
              @request = request
            end

            def params
              @params ||= (
                upstream_params = request.env['action_dispatch.request.path_parameters'] || {}
                symbolize(request.params).merge(symbolize(upstream_params))
              )
            end

            def url(path = nil)
              path = path.gsub(/^\//, '') if path.is_a?(String)
              uri = [host = String.new]
              host << "http#{'s' if request.ssl?}://"
              if forwarded?(request) or request.port != (request.ssl? ? 443 : 80)
                host << request.host_with_port
              else
                host << request.host
              end
              uri << request.script_name.to_s
              uri << (path ? path : request.path_info).to_s
              uri.filter { |s| s.bytesize > 0 }.join('/')
            end

            private

            attr_reader :request

            def symbolize(hash)
              hash.each.with_object({}) do |(k, v), h|
                h[k.to_sym] = v
              end
            end

            def forwarded?(req)
              req.env.include? HTTP_X_FORWARDED_HOST
            end
          end
        end
      end
    end
  end
end

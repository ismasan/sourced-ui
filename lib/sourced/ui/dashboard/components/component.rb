# frozen_string_literal: true

require 'phlex'
require 'sourced/ui/components/datastar_helpers'

module Sourced
  module UI
    module Dashboard
      module Components
        class Component < Phlex::HTML
          include Sourced::UI::Components::DatastarHelpers

          # Compatibility with Datastar
          def render_in(view_context)
            call(context: { view_context: })
          end

          private

          def helpers
            @helpers ||= context.fetch(:view_context)
          end

          class Helpers
            HTTP_X_FORWARDED_HOST = 'HTTP_X_FORWARDED_HOST'

            def initialize(request:)
              @request = request
              # Rack::Request#script_name seems to mutate when accessed repeatedly,
              # so we cache it here.
              @script_name = request.script_name.to_s
              @path_info = request.path_info.to_s
            end

            def url(path = nil)
              path = strip_leading_hash(path) if path.is_a?(String)
              host = String.new
              uri = [strip_leading_hash(script_name)]
              host << "http#{'s' if request.ssl?}://"
              if forwarded?(request) or request.port != (request.ssl? ? 443 : 80)
                host << request.host_with_port
              else
                host << request.host
              end
              uri << (path ? path : path_info).to_s
              uri = uri.filter { |s| !s.empty? }.join('/')
              host << '/' << uri
            end

            private

            attr_reader :request, :script_name, :path_info

            def strip_leading_hash(path)
              path.gsub(/^\//, '')
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

# frozen_string_literal: true

require 'sidereal'

module Sourced
  module UI
    module Dashboard
      module Components
        class Component < Sidereal::Components::BaseComponent
          private

          # Components render via `Sidereal::Router#component`, which calls
          # `component.call(context: router)`. That gives us the router
          # instance here, which mixes in `Sidereal::RequestHelpers` (providing
          # `#url`) — hence `helpers.url('/path')` Just Works.
          def helpers
            context
          end
        end
      end
    end
  end
end

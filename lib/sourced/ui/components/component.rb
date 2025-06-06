# frozen_string_literal: true

require 'phlex'
require 'sourced/ui/components/datastar_helpers'

module Sourced
  module UI
    module Components
      class Component < Phlex::HTML
        include Sourced::UI::Components::DatastarHelpers

        # Compatibility with Datastar
        def render_in(view_context)
          call(context: { view_context: })
        end
      end
    end
  end
end


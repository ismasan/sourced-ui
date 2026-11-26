# frozen_string_literal: true

require 'sourced/ui/dashboard/components/layout'
require 'sourced/ui/dashboard/components/boundary_maps'

module Sourced
  module UI
    module Dashboard
      module Components
        # The Topology page's boundaries map on its own, filling the window,
        # to pan and zoom around (BoundaryMaps, +full+).
        class TopologyMapPage < Component
          # @param boundaries [Sourced::UI::Boundaries]
          # @param grouped [Boolean] start by namespace
          # @param projections [Boolean, nil] start with reads shown, or nil for the default
          def initialize(boundaries:, grouped: false, projections: nil)
            @boundaries = boundaries
            @grouped = grouped
            @projections = projections
          end

          def view_template
            Layout(title: 'Topology map · Sourced') do
              if @boundaries.empty?
                div(id: 'container') do
                  div(class: 'reactor topology') do
                    p(class: 'muted') { 'No messages cross between the registered reactors: each keeps to its own.' }
                    a(href: helpers.url('/topology')) { '← Topology' }
                  end
                end
              else
                BoundaryMaps(boundaries: @boundaries, grouped: @grouped, projections: @projections, full: true)
              end
            end
          end
        end
      end
    end
  end
end

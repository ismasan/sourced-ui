# frozen_string_literal: true

require 'json'
require 'sourced/ui/dashboard/components/layout'

module Sourced
  module UI
    module Dashboard
      module Components
        class TopologyPage < Component
          register_element :eventlanes_diagram

          def initialize(topology:)
            @topology = topology
          end

          def view_template
            Layout(title: 'Topology - Sourced') do
              link(rel: 'stylesheet', href: 'https://eventlanes.app/wc/v1/eventlanes-diagram.css')
              script(type: 'module', src: 'https://eventlanes.app/wc/v1/eventlanes-diagram.js')

              div id: 'container', class: 'full-width' do
                schema = JSON.pretty_generate(version: '1.0', elements: @topology)
                # pre { code { schema } }
                eventlanes_diagram(
                  id: 'diagram',
                  width: '100%',
                  height: '100%',
                  readonly: 'false',
                  'show-minimap': 'true',
                  'show-layout-toggle': 'true',
                  schema: schema
                )
              end
            end
          end
        end
      end
    end
  end
end

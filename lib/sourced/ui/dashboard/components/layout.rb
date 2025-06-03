# frozen_string_literal: true

require 'sourced/ui/dashboard/components/component'

module Sourced
  module UI
    module Dashboard
      module Components
        class Layout < Component
          def initialize(title: 'Sourced Dashboard')
            @title = title
          end

          def view_template
            doctype

            html do
              head do
                meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
                title { @title }
                link(rel: 'stylesheet', href: helpers.url('/stylesheets/styles.css'))
                script(type: 'module', src: 'https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0-beta.11/bundles/datastar.js')
              end

              body(data: { 'signals' => '{"modal": false}' }) do
                div class: 'nav' do
                  div class: 'link-group' do
                    a(href: helpers.url) { 'System' }
                    a(href: helpers.url('/reactors')) { 'Reactors' }
                  end
                end

                yield if block_given?

                div(id: 'modal', data: { show: '$modal' })
              end
            end
          end
        end
      end
    end
  end
end

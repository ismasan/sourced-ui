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
                link(rel: 'stylesheet', href: helpers.url("/stylesheets/styles.css?r=#{Time.now}"))
                script(type: 'module', src: 'https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0-beta.11/bundles/datastar.js')
              end

              body(data: { 'signals' => '{"modal": false}' }) do
                div class: 'nav' do
                  if Sourced::UI::Dashboard.configuration.header_links.any?
                    div class: 'link-group custom' do
                      Sourced::UI::Dashboard.configuration.header_links.each do |link|
                        if link.url
                          a(href: helpers.url(link.href)) { link.label }
                        else
                          a(href: link.href) { link.label }
                        end
                      end
                    end
                  end

                  div class: 'link-group dashboard' do
                    Sourced::UI::Dashboard.configuration.header_links.each do |link|
                      a(href: helpers.url('/')) { 'System' }
                      a(href: helpers.url('/reactors'))  { 'Reactors' }
                    end
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

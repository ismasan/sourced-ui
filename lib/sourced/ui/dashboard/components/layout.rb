# frozen_string_literal: true

require 'sidereal'

module Sourced
  module UI
    module Dashboard
      module Components
        class Layout < Sidereal::Components::Layout
          # The dashboard is component-based and has no real page, but the
          # parent Layout reads `page.page_signals` and `page.channel_name`
          # from whatever it wraps. NullPage satisfies Sidereal::Page's type
          # contract while supplying the dashboard's defaults: a `modal`
          # signal and no per-page SSE channel.
          class NullPage < Sidereal::Page
            def page_signals = { modal: false }
            def channel_name = nil
          end

          NULL_PAGE = NullPage.new

          def initialize(title: 'Sourced Dashboard')
            super(NULL_PAGE)
            @title = title
          end

          def view_template
            doctype

            html do
              head do
                meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
                title { @title }
                link(rel: 'stylesheet', href: helpers.url("/stylesheets/styles.css?r=#{Time.now}"))
              end

              body do
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
                    a(href: helpers.url('/')) { 'System' }
                    a(href: helpers.url('/log')) { 'Log' }
                    a(href: helpers.url('/topology')) { 'Topology' }
                    a(href: helpers.url('/offsets')) { 'Offsets' }
                  end
                end

                yield if block_given?

                div(id: 'modal', data: { show: '$modal' })
              end
            end
          end

          private

          def helpers = context
        end
      end
    end
  end
end

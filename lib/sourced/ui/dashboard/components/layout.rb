# frozen_string_literal: true

require 'sidereal'

module Sourced
  module UI
    module Dashboard
      module Components
        class Layout < Sidereal::Components::Layout
          # The dashboard is component-based and has no real page, but the
          # parent Layout reads `page.page_signals` and `page.channel_names`
          # from whatever it wraps. NullPage satisfies Sidereal::Page's type
          # contract while supplying the dashboard's defaults: a `modal`
          # signal and no channels, so the layout opens no page stream
          # (the dashboard streams its own updates per component).
          class NullPage < Sidereal::Page
            def page_signals = { modal: false }
            def channel_names = []
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
                meta(charset: 'utf-8')
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

          # The dashboard's SSE routes stream their own updates, so it never
          # opens a page stream. Answering nil here, instead of letting
          # Sidereal::Page.stream_token find NULL_PAGE has no channels, keeps
          # the dashboard rendering where Sidereal isn't booted, since that
          # reads Sidereal.signer before checking the page's channels.
          def updates_url = nil
        end
      end
    end
  end
end

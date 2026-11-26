# frozen_string_literal: true

require 'sidereal'
require 'sourced/ui/dashboard/components/message_name'

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

          # The dashboard's sections, as the nav links them: label, path, and
          # the path prefixes of the pages within each (a reactor's pages are
          # reached from System, a message's from Log).
          SECTIONS = [
            ['System', '/', %w[/reactors]],
            ['Log', '/log', %w[/log /events]],
            ['Topology', '/topology', %w[/topology]],
            ['Offsets', '/offsets', %w[/offsets]]
          ].freeze

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
                    SECTIONS.each do |label, path, _|
                      a(href: helpers.url(path), aria: { current: ('page' if label == current_section) }) { label }
                    end
                  end
                end

                yield if block_given?

                div(id: 'modal', data: { show: '$modal' })
                # The message schema dialog MessageName opens.
                render MessageSchema::Dialog.new
              end
            end
          end

          private

          def helpers = context

          # The label of the section the current page is in, which the nav
          # marks as the current page; nil when it's in none.
          def current_section
            path = helpers.request.path_info
            return 'System' if path.empty? || path == '/'

            SECTIONS.find do |_, _, prefixes|
              prefixes.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
            end&.first
          end

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

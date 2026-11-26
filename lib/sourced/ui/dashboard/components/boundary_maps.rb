# frozen_string_literal: true

require 'json'
require 'sourced/ui/components'
require 'sourced/ui/dashboard/components/reactor_panel'

module Sourced
  module UI
    module Dashboard
      module Components
        # The boundaries map in a card with its switches: by reactor or by
        # namespace, with reads or without. All four drawings are rendered and
        # the switches show one, without a request.
        #
        # +full+ fills the window (TopologyMapPage): a toolbar instead of the
        # card's bar, and the maps pan and zoom (boundary_map.js, beside this
        # file, declared as an asset below). Otherwise it
        # links to that page, as it's set.
        class BoundaryMaps < Component
          # Pans and zooms the full screen map. An app linking it installs the
          # component (Dashboard::Service: +component BoundaryMaps+), and its
          # layout links the script on every page: it acts only on +full+ maps.
          javascript 'topology/boundary_map.js', path: 'boundary_map.js'

          # @param boundaries [Sourced::UI::Boundaries]
          # @param grouped [Boolean] start by namespace
          # @param projections [Boolean, nil] start with reads shown; nil to
          #   show them unless they outnumber the other links
          # @param full [Boolean] fill the window, panning and zooming
          def initialize(boundaries:, grouped: false, projections: nil, full: false)
            @boundaries = boundaries
            @grouped = boundaries.grouped
            @full = full
            # Full screen, a click on a box picks it (ReactorPanel), rather than
            # following its link; the picked one is lit.
            node_data = full ? method(:pick_data) : nil
            map = ->(b, reads, title) { Sourced::UI::Components::BoundaryMap.new(b, href:, projections: reads, title:, node_data:) }
            @maps = {
              reactors: [map.(boundaries, true, 'Reactor boundaries'), map.(boundaries, false, 'Reactor boundaries, without reads')],
              namespaces: [map.(@grouped, true, 'Namespace boundaries'), map.(@grouped, false, 'Namespace boundaries, without reads')]
            }
            reads, rest = boundaries.links.partition { it.kind == :projection }
            @toggle = !@maps[:reactors].last.empty? && reads.any?
            # Reads shown unless they outnumber the rest, as they do once a
            # system has a read model or two per decider: they'd hide it.
            @shown = !@toggle || (projections.nil? ? reads.size <= rest.size : projections)
            # Only when grouping puts reactors together.
            @by_namespace = @grouped.reactors.size < boundaries.reactors.size
            @start_grouped = @by_namespace && grouped
          end

          def view_template
            if @full
              signals = { projections: @shown, grouped: @start_grouped, selected: '' }.to_json
              div(class: 'topology-full', data: { signals:, 'pan-zoom' => true }) do
                render_toolbar
                div(class: 'topology-full__body') do
                  div(class: 'topology-full__maps') { render_canvases }
                  render ReactorPanel.empty
                end
              end
            else
              signals = { projections: @shown, grouped: @start_grouped }.to_json
              figure(class: 'chart-card', data: { signals: }) do
                figcaption(class: 'chart-card__bar') do
                  strong { 'Boundaries' }
                  span(class: 'muted') { 'Arrows run the way messages go. Hover a box to pick out its own.' }
                  div(class: 'chart-card__tools') do
                    render_switches
                    render_key
                    # Kept as the switches are set by an effect, not data-attr:href,
                    # which Phlex refuses: a nested name can't set a reference.
                    a(class: 'chart-card__expand', href: map_url, data: { effect: "el.href = #{map_url_expression}" }) { 'Full screen' }
                  end
                end
                render_canvases
              end
            end
          end

          private

          def render_toolbar
            div(class: 'topology-full__bar') do
              a(class: 'topology-full__back', href: helpers.url('/topology')) { '← Topology' }
              strong { 'Boundaries' }
              span(class: 'muted topology-full__hint') { 'Drag to pan, scroll to zoom, double-click to fit. Click a box for its detail.' }
              div(class: 'chart-card__tools') do
                render_switches
                render_key
                div(class: 'zoom-controls', role: 'group', aria: { label: 'Zoom' }) do
                  button(type: 'button', data: { zoom: 'out' }, title: 'Zoom out (-)', aria: { label: 'Zoom out' }) { '−' }
                  button(type: 'button', data: { zoom: 'fit' }, title: 'Fit (0)') { 'Fit' }
                  button(type: 'button', data: { zoom: 'in' }, title: 'Zoom in (+)', aria: { label: 'Zoom in' }) { '+' }
                  button(type: 'button', data: { fullscreen: true }, title: 'Full screen (f)') { 'Full screen' }
                end
              end
            end
          end

          def render_switches
            switch('By namespace', 'grouped', @start_grouped) if @by_namespace
            switch('Reads', 'projections', @shown) if @toggle
          end

          def render_key
            ul(class: 'em-key', aria: { label: 'Key' }) do
              li(class: 'em-key__item bm-key--command') { 'Dispatches / starts' }
              li(class: 'em-key__item bm-key--event') { 'Reacts to' }
              li(class: 'em-key__item bm-key--projection') { 'Reads' }
            end
          end

          def render_canvases
            @maps.each do |level, (full, driving)|
              next if level == :namespaces && !@by_namespace

              at = level == :namespaces ? '$grouped' : '!$grouped'
              visible = (level == :namespaces) == @start_grouped # what the signals start at
              if full.empty?
                map_canvas(at, visible) { p(class: 'muted topology__none') { 'Every crossing is between reactors in the same namespace.' } }
                next
              end
              # Without reads there may be nothing left: the full map stays.
              if driving.empty?
                map_canvas(at, visible) { render full }
              else
                map_canvas("#{at} && $projections", visible && @shown) { render full }
                map_canvas("#{at} && !$projections", visible && !@shown) { render driving }
              end
            end
          end

          def switch(text, signal, checked)
            label(class: 'switch') do
              input(type: 'checkbox', role: 'switch', checked:, data: { "bind:#{signal}" => true })
              span(class: 'switch__track', aria: { hidden: 'true' })
              plain text
            end
          end

          def map_canvas(show, visible, &)
            classes = @full ? 'topology-full__canvas' : 'chart-card__canvas'
            div(class: classes, style: ('display: none' unless visible), data: { show: }, &)
          end

          # The full screen map, as the switches are now.
          def map_url = helpers.url("/topology/map?grouped=#{@start_grouped}&reads=#{@shown}")

          def map_url_expression = "'#{helpers.url('/topology/map')}?grouped=' + $grouped + '&reads=' + $projections"

          # A box's click picks it, opening its panel, and its class lights it
          # while it's picked.
          def pick_data(reactor)
            id = reactor.group_id
            {
              'on:click__prevent' => ReactorPanel.pick(helpers, id),
              'class:is-selected' => "$selected == #{id.to_json}"
            }
          end

          def href = ->(group_id) { helpers.url("/reactors/#{group_id}") if @boundaries.reactor(group_id)&.reactor }
        end
      end
    end
  end
end

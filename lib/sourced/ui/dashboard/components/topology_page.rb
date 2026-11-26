# frozen_string_literal: true

require 'sourced/ui/components'
require 'sourced/ui/dashboard/components/layout'
require 'sourced/ui/dashboard/components/boundary_maps'

module Sourced
  module UI
    module Dashboard
      module Components
        # The system's reactors and the messages that cross between them: a
        # map (Components::BoundaryMap) and every crossing listed. What goes on
        # inside each reactor is on its own page.
        class TopologyPage < Component
          RELATIONS = {
            dispatches: 'dispatched',
            starts: 'started',
            reacts: 'reacted to',
            projects: 'projected',
            evolves: 'evolved from'
          }.freeze

          # @param boundaries [Sourced::UI::Boundaries]
          def initialize(boundaries:)
            @boundaries = boundaries
          end

          def view_template
            Layout(title: 'Topology · Sourced') do
              div(id: 'container') do
                div(class: 'reactor topology') do
                  render_header
                  if @boundaries.empty?
                    section(class: 'panel') do
                      p(class: 'muted') { 'No messages cross between the registered reactors: each keeps to its own.' }
                    end
                  else
                    render BoundaryMaps.new(boundaries: @boundaries)
                    render_crossings
                  end
                  render_isolated
                  render_unattributed
                end
              end
            end
          end

          private

          def render_header
            header(class: 'reactor__header') do
              nav(class: 'crumbs', aria: { label: 'Breadcrumb' }) do
                a(href: helpers.url('/')) { 'System' }
                span(class: 'crumbs__sep', aria: { hidden: 'true' }) { '/' }
                span { 'Topology' }
              end
              div(class: 'reactor__title') { h1 { 'Topology' } }
              p(class: 'topology__lead muted') do
                plain 'Where messages cross from one reactor to another: the commands one dispatches to another, '
                plain "and the events one reacts to or reads from another. Each reactor's own commands and events are on its page."
              end
              dl(class: 'facts') do
                fact('Reactors') { @boundaries.reactors.size.to_s }
                fact('Crossings') { @boundaries.crossings.size.to_s }
                fact('Self-contained') { @boundaries.isolated.size.to_s }
              end
            end
          end

          def fact(term, &)
            div(class: 'facts__item') do
              dt { term }
              dd(&)
            end
          end

          # A row for each reactor pair one way and how messages cross it:
          # the messages listed together.
          def render_crossings
            rows = @boundaries.crossings
              .group_by { [it.from, it.to, it.relation] }
              .sort_by { |(from, to, _), _| [reactor_label(from), to ? reactor_label(to) : '~'] }
            section(class: 'panel') do
              div(class: 'panel__head') do
                h2 { "Crossings (#{@boundaries.crossings.size})" }
                p(class: 'muted') { 'Every message one reactor sends that another takes.' }
              end
              table(class: 'data-table topology__table') do
                thead do
                  tr do
                    th { 'From' }
                    th { 'To' }
                    th { 'How' }
                    th { 'Messages' }
                  end
                end
                tbody do
                  rows.each do |(from, to, relation), crossings|
                    tr do
                      td { reactor_link(from) }
                      td { to ? reactor_link(to) : span(class: 'muted') { 'no registered reactor' } }
                      td { span(class: "bm-relation bm-relation--#{relation}") { RELATIONS.fetch(relation) } }
                      td do
                        ul(class: 'bm-messages') do
                          crossings.each do |crossing|
                            li do
                              span(class: "bm-message bm-message--#{crossing.kind}", title: crossing.message) { crossing.name }
                              span(class: 'muted') { " in #{crossing.via}" } if crossing.via && relation == :reacts
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end

          def render_isolated
            isolated = @boundaries.isolated
            return if isolated.empty? || @boundaries.empty?

            section(class: 'panel') do
              div(class: 'panel__head') do
                h2 { "Self-contained (#{isolated.size})" }
                p(class: 'muted') { 'No message crosses into or out of these, from other reactors.' }
              end
              ul(class: 'topology__isolated') do
                isolated.each { |reactor| li { reactor_pill(reactor) } }
              end
            end
          end

          # Events reactors take that none declares producing, and no reactor
          # defines: where they come from isn't known.
          def render_unattributed
            list = @boundaries.unattributed
            return if list.empty?

            section(class: 'panel') do
              div(class: 'panel__head') do
                h2 { "Unknown sources (#{list.size})" }
                p(class: 'muted') { "Taken by these reactors, but no reactor declares appending them." }
              end
              table(class: 'data-table') do
                tbody do
                  list.each do |id, name, (group, relation, _via)|
                    tr do
                      td { span(class: 'bm-message bm-message--event', title: id) { name } }
                      td { reactor_link(group) }
                      td { span(class: "bm-relation bm-relation--#{relation}") { RELATIONS.fetch(relation) } }
                    end
                  end
                end
              end
            end
          end

          def href = ->(group_id) { helpers.url("/reactors/#{group_id}") if @boundaries.reactor(group_id)&.reactor }

          def reactor_label(group_id) = @boundaries.reactor(group_id)&.label || group_id

          # A reactor's name and kind, linked to its page when it has one.
          def reactor_pill(reactor)
            klass = reactor.reactor
            kind = (Module === klass && Sourced::UI::Boundaries::KINDS.find { |base, _| klass <= base }&.last) || 'reactor'
            url = href.call(reactor.group_id)
            attrs = { class: "reactor-pill reactor-pill--#{kind}", title: reactor.group_id }
            content = proc do
              span(class: 'reactor-pill__name') { reactor.label }
              span(class: 'reactor-pill__kind') { kind }
            end
            url ? a(href: url, **attrs, &content) : span(**attrs, &content)
          end

          def reactor_link(group_id)
            url = href.call(group_id)
            return code { group_id } unless url

            a(href: url, title: group_id) { reactor_label(group_id) }
          end
        end
      end
    end
  end
end

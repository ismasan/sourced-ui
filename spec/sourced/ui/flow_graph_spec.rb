# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'
require_relative '../../support/spec_shop'

RSpec.describe Sourced::UI::FlowGraph do
  def cmd(id, group, produces) = { type: 'command', id:, name: id, group_id: group, produces:, schema: {} }
  def evt(id, group) = { type: 'event', id:, name: id, group_id: group, produces: [] }
  def aut(id, group, consumes, produces) = { type: 'automation', id:, name: id, group_id: group, consumes:, produces: }
  def rm(id, group, consumes, produces) = { type: 'readmodel', id:, name: id, group_id: group, consumes:, produces: }

  # Todos' Send and Rename append Sent and Renamed. Calendar registered Sent
  # first. Lists reads both, and on Renamed (only) has Notifier notify.
  let(:topology) do
    [
      rm('calendar-rm', 'Calendar', %w[sent], []),
      evt('sent', 'Calendar'),
      cmd('send', 'Todos', %w[sent]),
      cmd('rename', 'Todos', %w[renamed]),
      evt('renamed', 'Todos'),
      rm('lists-rm', 'Lists', %w[sent renamed], %w[renamed-Lists-aut]),
      aut('renamed-Lists-aut', 'Lists', %w[lists-rm], %w[notify]),
      cmd('notify', 'Notifier', %w[notified]),
      evt('notified', 'Notifier'),
      cmd('unrelated', 'Other', %w[other]),
      evt('other', 'Other')
    ]
  end

  def edges(graph) = graph.edges.map { [it.from, it.to] }

  it "draws every flow the reactor takes part in, each node once, flows meeting at what they share" do
    graph = described_class.build(topology, 'Todos')

    expect(graph.starts).to eq(%w[send rename])
    expect(graph.nodes.map(&:id)).to contain_exactly(
      'calendar-rm', 'sent', 'send', 'rename', 'renamed', 'lists-rm', 'renamed-Lists-aut', 'notify', 'notified'
    )
    expect(edges(graph)).to include(%w[sent lists-rm], %w[renamed lists-rm], %w[lists-rm renamed-Lists-aut])
    expect(graph.nodes.select(&:own).map(&:id)).to contain_exactly('send', 'rename', 'sent', 'renamed')
  end

  it "follows a projector's reaction only once the event it reacts to is in the graph" do
    graph = described_class.build(topology, 'Calendar')

    expect(graph.starts).to eq(%w[send])
    expect(graph.nodes.map(&:id)).not_to include('renamed-Lists-aut', 'notify')
  end

  it 'gives an event to the reactor appending it, not the one registering it first' do
    graph = described_class.build(topology, 'Todos')

    expect(graph.nodes.find { it.id == 'sent' }).to have_attributes(group_id: 'Todos', own: true)
  end

  it 'starts a loop only reactions dispatch into at its reactor\'s command, the edge back kept' do
    graph = described_class.build(topology + [aut('notified-Todos-aut', 'Todos', %w[notified], %w[rename])], 'Notifier')

    expect(graph.starts).to eq(%w[notify])
    expect(edges(graph)).to include(%w[notified-Todos-aut rename], %w[rename renamed])
  end

  it 'starts at an event nothing appends, if something consumes it' do
    graph = described_class.build(topology + [evt('imported', 'Calendar'), rm('imports-rm', 'Calendar', %w[imported], [])],
                                  'Calendar')

    expect(graph.starts).to eq(%w[send imported])
  end

  it "draws SpecShop's order flow left to right, its loop back drawn back" do
    graph = described_class.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::Orders.group_id)
    html = Sourced::UI::Components::FlowDiagram.new(graph).call

    expect(graph.starts).to eq([SpecShop::PlaceOrder.type])
    expect(graph.nodes.map(&:id)).to include(SpecShop::ConfirmOrder.type, SpecShop::PaymentCharged.type)
    expect(html).to include('class="flow-diagram flow-diagram--right"', 'matrix(0 1 1 0 0 0)', '>PlaceOrder<', '>ChargePayment<')
  end

  it 'ends a loop running far back at a proxy of where it goes back to' do
    chain = [cmd('c0', 'L', %w[e0]), evt('e0', 'L')] +
            (1..4).flat_map { |i| [aut("a#{i}", 'L', ["e#{i - 1}"], ["c#{i}"]), cmd("c#{i}", 'L', ["e#{i}"]), evt("e#{i}", 'L')] } +
            [aut('back', 'L', %w[e4], %w[c1])]
    html = Sourced::UI::Components::FlowDiagram.new(described_class.build(chain, 'L')).call

    expect(html).to include('flow-diagram__node--proxy', '↻ c1')
    expect(html).not_to include('flow-diagram__edge--back')
  end

  it 'draws a short loop back as a dashed edge against the flow' do
    nodes = [cmd('c', 'L', %w[e]), evt('e', 'L'), aut('again', 'L', %w[e], %w[c])]
    html = Sourced::UI::Components::FlowDiagram.new(described_class.build(nodes, 'L')).call

    expect(html).to include('flow-diagram__edge--back')
    expect(html).not_to include('flow-diagram__node--proxy')
  end

  describe 'picking a node out' do
    # A node's [token, upstream tokens], by the name in its title.
    def picks(html, name) = html.match(/data-node="(\w+)" data-up="([^"]*)"[^>]*><title>\w+: #{name}\n/).captures

    it 'lists on each node and edge the nodes it\'s downstream of, by edges running forward' do
      nodes = [cmd('c', 'L', %w[e]), evt('e', 'L'), aut('again', 'L', %w[e], %w[c]), rm('r', 'L', %w[e], [])]
      html = Sourced::UI::Components::FlowDiagram.new(described_class.build(nodes, 'L')).call
      token = ->(name) { picks(html, name).first }
      up = ->(name) { picks(html, name).last.split }

      expect(up.('c')).to eq([token.('c')])
      expect(up.('r')).to contain_exactly(token.('c'), token.('e'), token.('r'))
      # The edge back from again to c doesn't make c downstream of again.
      expect(up.('again')).to contain_exactly(token.('c'), token.('e'), token.('again'))
      expect(html).to include(%(.flow-diagram:has([data-node="#{token.('e')}"]:hover) [data-up]:not([data-up~="#{token.('e')}"])))
      expect(html.scan('tabindex="0"').size).to eq(4)
    end

    it 'adds what node_data gives a node, a click instead of its reactor\'s link' do
      data = ->(node) { node.kind == :command ? { 'on:click' => "open('#{node.id}')" } : {} }
      html = Sourced::UI::Components::FlowDiagram.new(described_class.build(topology, 'Notifier'), href: ->(_) { '/r' }, node_data: data).call

      expect(html).to include(%(data-on:click="open('rename')"), 'is-clickable')
      expect(html).not_to match(%r{<a href="/r"[^>]*>\s*<g[^>]*>\s*<title>command})
    end
  end

  it 'draws top to bottom, as LayeredLayout lays out, or refuses another direction' do
    graph = described_class.build(topology, 'Todos')
    down = Sourced::UI::Components::FlowDiagram.new(graph, direction: :down).call
    right = Sourced::UI::Components::FlowDiagram.new(graph).call
    size = ->(html) { html[/width="(\d+)" height="(\d+)"/].scan(/\d+/).map(&:to_i) }

    expect(down).to include('flow-diagram--down')
    expect(down).not_to include('matrix(')
    # Taller than wide down, wider than tall across.
    expect(size.(down).then { |w, h| h > w }).to be(true)
    expect(size.(right).then { |w, h| w > h }).to be(true)
    expect { Sourced::UI::Components::FlowDiagram.new(graph, direction: :left) }.to raise_error(ArgumentError)
  end
end

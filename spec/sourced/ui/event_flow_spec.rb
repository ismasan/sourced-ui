# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'

RSpec.describe Sourced::UI::EventFlow do
  def cmd(id, group, produces) = { type: 'command', id:, name: id, group_id: group, produces: }
  def evt(id, group) = { type: 'event', id:, name: id, group_id: group, produces: [] }
  def aut(id, group, consumes, produces) = { type: 'automation', id:, name: id, group_id: group, consumes:, produces: }
  def rm(id, group, consumes, produces) = { type: 'readmodel', id:, name: id, group_id: group, consumes:, produces: }

  # Booking's Pay confirms a booking; Reviews asks for a review once it's
  # confirmed and takes one; Summaries reads reviews and flags poor ones.
  let(:topology) do
    [
      cmd('pay', 'Booking', ['confirmed']),
      cmd('cancel', 'Booking', ['cancelled']),
      evt('confirmed', 'Booking'),
      evt('cancelled', 'Booking'),
      aut('confirmed-Reviews-aut', 'Reviews', ['confirmed'], ['request']),
      cmd('request', 'Reviews', ['requested']),
      cmd('submit', 'Reviews', ['submitted']),
      cmd('flag', 'Reviews', ['flagged']),
      evt('requested', 'Reviews'),
      evt('submitted', 'Reviews'),
      evt('flagged', 'Reviews'),
      rm('summaries-rm', 'Summaries', %w[requested submitted], ['submitted-Summaries-aut']),
      aut('submitted-Summaries-aut', 'Summaries', ['summaries-rm'], ['flag'])
    ]
  end

  it "lays out a reactor's flow as a timeline: what triggers it, and downstream" do
    flow = described_class.build(topology, 'Reviews')

    expect(flow.nodes.map(&:id)).to eq(%w[
      pay confirmed confirmed-Reviews-aut request requested submit submitted
      summaries-rm submitted-Summaries-aut flag flagged
    ])
    expect(flow.nodes.map(&:column)).to eq((0..10).to_a)
    expect(flow.nodes.reject(&:own).map(&:id)).to eq(%w[pay confirmed summaries-rm submitted-Summaries-aut])
    expect(flow.lanes.map(&:id)).to eq(%w[automations interactions events:Reviews events:Booking])
    expect(flow.edges.map { [it.from, it.to] }).to include(%w[submitted summaries-rm], %w[submitted-Summaries-aut flag])
    expect(flow).not_to be_truncated
  end

  it "leaves out what doesn't lead to or from the reactor" do
    flow = described_class.build(topology, 'Reviews')

    expect(flow.nodes.map(&:id)).not_to include('cancel', 'cancelled')
  end

  it 'starts a read model at the commands appending the events it reads' do
    flow = described_class.build(topology, 'Summaries')

    expect(flow.nodes.first(4).map(&:id)).to eq(%w[request requested submit submitted])
  end

  it 'stops a long flow, and says so' do
    chain = (0...12).flat_map { |i| [cmd("c#{i}", 'Long', ["e#{i}"]), evt("e#{i}", 'Long'), aut("a#{i}", 'Next', ["e#{i}"], ["c#{i + 1}"])] }
    flow = described_class.build(chain, 'Long')

    expect(flow).to be_truncated
    expect(flow.nodes.size).to be <= described_class::MAX_NODES
  end

  it 'draws as an event model, linking other reactors' do
    flow = described_class.build(topology, 'Reviews')
    svg = Sourced::UI::Components::EventModel.new(flow, href: ->(group) { "/reactors/#{group}" }).call

    expect(svg).to include('event-model__node--command', 'event-model__node--event', 'event-model__node--readmodel',
                           'event-model__node--automation', 'event-model__robot', 'href="/reactors/Summaries"')
    expect(svg).not_to include('href="/reactors/Reviews"')
  end
end

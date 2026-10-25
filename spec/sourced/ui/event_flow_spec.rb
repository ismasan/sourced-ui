# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'

RSpec.describe Sourced::UI::EventFlow do
  def cmd(id, group, produces, schema: {}) = { type: 'command', id:, name: id, group_id: group, produces:, schema: }
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
      cmd('submit', 'Reviews', ['submitted'], schema: {
        'properties' => {
          'booking_id' => { 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'string', 'format' => 'uuid' }] },
          'rating' => { 'type' => 'integer' },
          'tags' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
          'mood' => { 'type' => 'string', 'enum' => %w[happy sad] }
        },
        'required' => %w[booking_id rating]
      }),
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
      pay confirmed confirmed-Reviews-aut request requested summaries-rm submit submitted
      summaries-rm submitted-Summaries-aut flag flagged
    ])
    expect(flow.nodes.map(&:column)).to eq((0..11).to_a)
    expect(flow.nodes.reject(&:own).map(&:id)).to eq(%w[pay confirmed summaries-rm summaries-rm submitted-Summaries-aut])
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

    expect(flow.nodes.first(5).map(&:id)).to eq(%w[request requested summaries-rm submit submitted])
  end

  it 'draws a node reached from several once after each, going on downstream only from the last' do
    flow = described_class.build([
      cmd('c1', 'Booking', ['e1']), cmd('c2', 'Booking', ['e2']), evt('e1', 'Booking'), evt('e2', 'Booking'),
      rm('rm1', 'Booking', %w[e1 e2], ['aut1']), aut('aut1', 'Booking', ['rm1'], [])
    ], 'Booking')

    expect(flow.nodes.map { [it.id, it.column] }).to eq([['c1', 0], ['e1', 1], ['rm1', 2], ['c2', 3], ['e2', 4], ['rm1', 5], ['aut1', 6]])
    copy, rm1 = flow.nodes.select { it.id == 'rm1' }
    expect(copy.key).not_to eq(rm1.key)
    expect(flow.edges.map { [it.from, it.to] }).to contain_exactly(
      %w[c1 e1], %w[c2 e2], ['e1', copy.key], ['e2', rm1.key], [rm1.key, 'aut1']
    )
  end

  it 'draws an event appended by several commands after each, stacked with their other events' do
    flow = described_class.build([
      cmd('c1', 'Booking', %w[e1 shared]), cmd('c2', 'Booking', ['shared']),
      evt('e1', 'Booking'), evt('shared', 'Booking')
    ], 'Booking')

    expect(flow.nodes.map { [it.id, it.column, it.row] }).to eq([['c1', 0, 0], ['e1', 1, 0], ['shared', 1, 1], ['c2', 2, 0], ['shared', 3, 0]])
  end

  it 'draws a cycle forward, the node it comes back to drawn again' do
    flow = described_class.build([
      cmd('c1', 'Booking', ['e1']), evt('e1', 'Booking'), aut('aut1', 'Booking', ['e1'], ['c1'])
    ], 'Booking')

    expect(flow.nodes.map(&:id)).to eq(%w[aut1 c1 e1 aut1])
    expect(flow.edges.map { |e| [e.from, e.to].map { k = it; flow.nodes.find { it.key == k }.column } }).to all(satisfy { |from, to| to > from })
  end

  it 'stacks the events a node may append in one column' do
    flow = described_class.build([cmd('pay', 'Booking', %w[paid declined]), evt('paid', 'Booking'), evt('declined', 'Booking')], 'Booking')
    paid, declined = %w[paid declined].map { |id| flow.nodes.find { it.id == id } }

    expect([paid.column, declined.column]).to eq([1, 1])
    expect([paid.row, declined.row]).to eq([0, 1])
    expect(flow.lanes.find { it.kind == :event }.rows).to eq(2)
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

  it 'names classes by as much of their namespace as tells them apart' do
    started = %w[X Bluesky].map { |child| { type: 'event', id: "#{child.downcase}.started", name: "Connections::#{child}::Started", group_id: 'Account', produces: [] } }
    flow = described_class.build([cmd('connect', 'Account', %w[x.started bluesky.started]), *started], 'Account')
    svg = Sourced::UI::Components::EventModel.new(flow).call

    expect(svg).to include('>X::Started<', '>Bluesky::Started<', '>connect<')
    expect(svg).not_to include('>Started<', 'event-model__name">Connections::')
  end

  it "names a machine part's state event for the part" do
    active = { type: 'event', id: 'account.active', name: 'Account::Active::State', group_id: 'Account', produces: [], transition: true }
    flow = described_class.build([cmd('reinstate', 'Account', %w[account.active]), active], 'Account')
    svg = Sourced::UI::Components::EventModel.new(flow).call

    expect(svg).to include('event-model__name">Active<')
    expect(svg).not_to include('event-model__name">State<')
  end

  describe 'with schemas' do
    let(:model) { Sourced::UI::Components::EventModel }
    let(:flow) { described_class.build(topology, 'Reviews') }

    it "lists a message's payload fields in its box, optional ones marked" do
      svg = model.new(flow, schemas: true).call

      expect(svg).to include('>booking_id<', '>uuid<', '>rating<', '>integer<', '>tags?<', '>[string]<', '>mood?<', '>happy|sad<')
      expect(svg).to include('marker-end="url(#em-arrow-schemas)"')
    end

    it 'leaves fields out without' do
      expect(model.new(flow).call).not_to include('>booking_id<')
    end

    it 'says whether any message has fields to list' do
      expect(model.schemas?(flow)).to be(true)
      expect(model.schemas?(described_class.build(topology.map { it.except(:schema) }, 'Reviews'))).to be(false)
    end
  end
end

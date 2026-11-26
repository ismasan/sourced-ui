# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'
require_relative '../../support/spec_shop'
require_relative '../../support/spec_light'

RSpec.describe Sourced::UI::Boundaries do
  subject(:boundaries) { described_class.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::REACTORS) }

  def crossing(from, to, name)
    boundaries.crossings.find { it.from == from.group_id && it.to == to&.group_id && it.name == name.name }
  end

  it 'takes events from the decider appending them, not whichever reactor registered first' do
    # Listings registers first, so the topology's event node names it.
    expect(Sourced::Topology.build(SpecShop::REACTORS).find { it.id == SpecShop::OrderPlaced.type }.group_id)
      .to eq(SpecShop::Listings.group_id)

    expect(crossing(SpecShop::Orders, SpecShop::Listings, SpecShop::OrderPlaced).relation).to eq(:projects)
    expect(boundaries.crossings.select { it.from == SpecShop::Listings.group_id }).to be_empty
  end

  it 'has events reacted to and commands dispatched cross the way the message goes' do
    expect(crossing(SpecShop::Orders, SpecShop::Checkout, SpecShop::OrderPlaced))
      .to have_attributes(kind: :event, relation: :reacts, via: 'reaction(SpecShop::OrderPlaced)')
    expect(crossing(SpecShop::Checkout, SpecShop::Payments, SpecShop::ChargePayment))
      .to have_attributes(kind: :command, relation: :dispatches)
    expect(crossing(SpecShop::Checkout, SpecShop::Orders, SpecShop::ConfirmOrder).relation).to eq(:dispatches)
  end

  it 'has a parent machine start its child, and the child finish back into it' do
    expect(crossing(SpecShop::Shipment, SpecShop::Parcel, SpecShop::Parcel::Started).relation).to eq(:starts)
    expect(crossing(SpecShop::Parcel, SpecShop::Shipment, SpecShop::Parcel::Finished).relation).to eq(:reacts)
  end

  it "leaves out what goes on inside a reactor" do
    expect(boundaries.crossings).to all(satisfy { it.from != it.to })
    expect(boundaries.crossings.map(&:name)).not_to include(SpecShop::PlaceOrder.name, SpecShop::OrderConfirmed.name)
  end

  it 'links each pair of reactors one way, by kind' do
    links = boundaries.links.to_h { [[it.from, it.to], it.kind] }
    expect(links).to include(
      [SpecShop::Orders.group_id, SpecShop::Listings.group_id] => :projection,
      [SpecShop::Orders.group_id, SpecShop::Checkout.group_id] => :event,
      [SpecShop::Checkout.group_id, SpecShop::Orders.group_id] => :command,
      [SpecShop::Shipment.group_id, SpecShop::Parcel.group_id] => :command
    )
    expect(boundaries.links.map(&:id).uniq.size).to eq(boundaries.links.size)
  end

  it 'lists the commands each reactor takes from outside' do
    expect(boundaries.reactor(SpecShop::Orders.group_id).entries).to eq([SpecShop::PlaceOrder.type])
    expect(boundaries.reactor(SpecShop::Payments.group_id).entries).to be_empty
    # Its Stop is its parent's to send.
    expect(boundaries.reactor(SpecShop::Parcel.group_id).entries).to eq([SpecShop::Deliver.type])
  end

  describe 'from a topology alone' do
    def node(type, id, group, **rest) = { type:, id:, name: "X::#{id}", group_id: group, group_label: group, produces: [], **rest }

    it 'lists consumed events nobody declares appending, and commands sent to no registered reactor' do
      topology = [
        node('command', 'a.go', 'a', produces: ['a.went']),
        node('automation', 'b-aut', 'b', consumes: ['a.went', 'mystery'], produces: ['elsewhere.do']),
        node('event', 'a.went', 'a'),
        node('event', 'mystery', 'a')
      ]
      boundaries = described_class.build(topology)

      expect(boundaries.unattributed).to eq([['mystery', 'X::mystery', ['b', :reacts, 'X::b-aut']]])
      expect(boundaries.crossings.map { [it.from, it.to, it.message] })
        .to contain_exactly(['a', 'b', 'a.went'], ['b', nil, 'elsewhere.do'])
      expect(boundaries.links.map { [it.from, it.to] }).to eq([['a', 'b']])
    end

    it 'lists the reactors nothing crosses into or out of' do
      boundaries = described_class.build([node('command', 'c.go', 'c', produces: [])])
      expect(boundaries).to be_empty
      expect(boundaries.isolated.map(&:group_id)).to eq(['c'])
    end
  end
end

RSpec.describe Sourced::UI::Components::BoundaryMap do
  let(:boundaries) { Sourced::UI::Boundaries.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::REACTORS) }

  it 'draws a box for each linked reactor, linked to its page, and an arrow for each link' do
    html = described_class.new(boundaries, href: ->(id) { "/reactors/#{id}" }).call
    expect(html.scan('class="boundary-map__node ').size).to eq(6)
    expect(html.scan('class="boundary-map__edge ').size).to eq(boundaries.links.size)
    expect(html).to include('href="/reactors/spec_shop.checkout"', '>ChargePayment<', 'decider · 1 from outside')
  end

  it 'leaves out reads, and the reactors only they link, without projections' do
    html = described_class.new(boundaries, projections: false).call
    expect(html).not_to include('boundary-map__edge--projection', 'SpecShop::Listings')
    expect(html.scan('class="boundary-map__node ').size).to eq(5)
  end
end

RSpec.describe Sourced::UI::Components::BoundaryMap, 'drawn twice on a page' do
  it 'gives each drawing arrowheads of its own' do
    boundaries = Sourced::UI::Boundaries.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::REACTORS)
    ids = [true, false].map { described_class.new(boundaries, projections: it).call.scan(/<marker id="([^"]+)"/).flatten }
    expect(ids[0] & ids[1]).to be_empty
  end
end

require 'sourced/ui/dashboard'

RSpec.describe Sourced::UI::Dashboard::Components::TopologyPage do
  def render(reactors)
    context = Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path).new({}, '/topology'))
    described_class.new(boundaries: Sourced::UI::Boundaries.build(Sourced::Topology.build(reactors), reactors)).call(context:)
  end

  it 'lists the self-contained reactors beside the crossings' do
    html = render(SpecShop::REACTORS + [SpecLight])
    expect(html).to include('Self-contained (1)', 'href="/reactors/spec_light"', 'Crossings (8)')
  end

  it 'says so when nothing crosses' do
    expect(render([SpecLight])).to include('No messages cross between the registered reactors')
  end
end

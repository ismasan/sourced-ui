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

RSpec.describe Sourced::UI::Components::BoundaryMap, 'around a hub' do
  # A reactor appending events that five others react to, each dispatching
  # commands back, and four read models reading its events: one gap crossed
  # by many lines, half of them labelled. Laid out with a slot per label in
  # the gap, the labels pushed lines out past their ends, up to 160px.
  let(:boundaries) do
    node = ->(type, id, group, **rest) { { type:, id:, name: "Hub::#{id.split('.').last}", group_id: group, group_label: group, produces: [], **rest } }
    topology = (1..5).flat_map do |n|
      events = (1..2).map { "hub.Spoke#{n}Outcome#{it}Recorded" }
      commands = (1..2).map { "hub.RecordSpoke#{n}Outcome#{it}" }
      commands.zip(events).flat_map { |c, e| [node.('command', c, 'hub', produces: [e]), node.('event', e, 'hub')] } +
        [node.('automation', "spoke#{n}-aut", "spoke#{n}", consumes: events, produces: commands), node.('command', "spoke#{n}.Handle", "spoke#{n}")]
    end
    events = topology.select { it[:type] == 'event' }.map { it[:id] }.first(3)
    topology += (1..4).map { { type: 'readmodel', id: "list#{it}-rm", name: "list#{it}", group_id: "list#{it}", group_label: "list#{it}", consumes: events, produces: [] } }
    Sourced::UI::Boundaries.build(topology)
  end
  let(:map) { described_class.new(boundaries) }

  def rect(spot) = [spot[:x], spot[:y], spot[:x] + spot[:w], spot[:y] + spot[:h]]
  def overlap?((ax1, ay1, ax2, ay2), (bx1, by1, bx2, by2)) = ax1 < bx2 && bx1 < ax2 && ay1 < by2 && by1 < ay2

  it 'places every label clear of the others and of the boxes' do
    placed = map.instance_variable_get(:@placed).values.map { rect(it) }
    boxes = map.instance_variable_get(:@layout).boxes.values.map { [it.x, it.y, it.x + described_class::BOX_W, it.y + described_class::BOX_H] }

    expect(placed.size).to eq(10)
    expect(placed.combination(2).count { |a, b| overlap?(a, b) }).to eq(0)
    expect(placed.product(boxes).count { |a, b| overlap?(a, b) }).to eq(0)
  end

  it 'runs each line within the span of its ends, not out to a label and back' do
    map.instance_variable_get(:@layout).routes.each_value do |route|
      xs = route.points.map(&:first)
      lo, hi = [xs.first, xs.last].minmax
      expect(xs).to all(be_between(lo - 4, hi + 4))
    end
  end
end

RSpec.describe Sourced::UI::Boundaries::Grouped do
  def node(type, id, group, **rest) = { type:, id:, name: "X::#{id}", group_id: group, group_label: group, produces: [], **rest }

  # billing.invoices dispatches to billing.payments (inside billing), reacts
  # to orders.cart's event (orders into billing), and audit, a reactor of
  # one segment, reads orders.cart's event.
  let(:boundaries) do
    Sourced::UI::Boundaries.build([
      node('command', 'orders.checkout', 'orders.cart', produces: ['orders.checked_out']),
      node('event', 'orders.checked_out', 'orders.cart'),
      node('automation', 'invoices-aut', 'billing.invoices', consumes: ['orders.checked_out'], produces: ['billing.charge']),
      node('command', 'billing.charge', 'billing.payments', produces: []),
      node('readmodel', 'audit-rm', 'audit', consumes: ['orders.checked_out'])
    ])
  end
  subject(:grouped) { boundaries.grouped }

  it 'puts reactors sharing a group_id prefix together, a reactor of one segment alone' do
    expect(grouped.reactors.map(&:group_id)).to contain_exactly('orders.*', 'billing.*', 'audit')
    billing = grouped.reactor('billing.*')
    expect(billing).to have_attributes(members: contain_exactly(have_attributes(group_id: 'billing.invoices'), have_attributes(group_id: 'billing.payments')),
                                       inside: 1, reactor: nil)
    expect(grouped.reactor('audit')).to be_a(Sourced::UI::Boundaries::Reactor)
  end

  it 'links only what crosses from one namespace to another' do
    expect(grouped.links.map { [it.from, it.to, it.kind] })
      .to contain_exactly(['orders.*', 'billing.*', :event], ['orders.*', 'audit', :projection])
    expect(grouped.crossings.map(&:name)).not_to include('X::billing.charge')
  end

  it 'is drawn like reactors, a box per namespace' do
    html = Sourced::UI::Components::BoundaryMap.new(grouped).call
    expect(html).to include('boundary-map__node--namespace', '2 reactors · 1 inside')
    expect(html.scan(/<marker id="bm-arrow-ns-all/).size).to eq(3)
  end
end

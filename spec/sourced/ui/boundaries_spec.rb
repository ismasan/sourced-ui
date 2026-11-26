# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'
require_relative '../../support/spec_shop'
require_relative '../../support/spec_light'
require_relative '../../support/spec_alarm'

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

  it "dims what isn't a reactor's own lines while it's hovered, or picked with nothing hovered" do
    html = described_class.new(boundaries).call
    expect(html).to include(
      '.boundary-map:has([data-node="spec_shop.checkout"]:hover) [data-ends]:not([data-ends~="spec_shop.checkout"])',
      '.boundary-map:not(:has([data-node]:hover)):has([data-node="spec_shop.checkout"].is-selected) [data-ends]:not([data-ends~="spec_shop.checkout"])'
    )
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
    context = Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path, :path_info).new({}, '/topology', '/topology'))
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

RSpec.describe Sourced::UI::Dashboard::Components::TopologyMapPage do
  let(:boundaries) { Sourced::UI::Boundaries.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::REACTORS) }

  def render(**options)
    context = Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path, :path_info).new({}, '/topology/map', '/topology/map'))
    described_class.new(boundaries:, **options).call(context:)
  end

  it 'fills the window with the map, to pan and zoom, and its controls' do
    html = render
    expect(html).to include('class="topology-full"', 'data-pan-zoom',
                            'data-zoom="fit"', 'data-fullscreen', 'href="/topology"')
    # Reactors with reads and without; by namespace, all inside one.
    expect(html.scan('class="topology-full__canvas"').size).to eq(3)
  end

  it 'starts with the switches as given' do
    html = render(grouped: true, projections: false)
    expect(html).to include('{&quot;projections&quot;:false,&quot;grouped&quot;:true,&quot;selected&quot;:&quot;&quot;}')
    # The namespace view shows; the reactor maps start hidden.
    expect(html).to match(/topology-full__canvas" style="display: none" data-show="!\$grouped && \$projections"/)
  end
end

RSpec.describe Sourced::UI::Dashboard::Components::BoundaryMaps do
  it 'declares its pan and zoom script, from the file beside it' do
    script = described_class.assets.find { it.name == 'topology/boundary_map.js' }
    expect(script).to have_attributes(kind: :js, path: File.expand_path('../../../lib/sourced/ui/dashboard/components/boundary_map.js', __dir__))
    expect(File).to exist(script.path)
  end

  it 'links the card to the full screen map, as its switches are set' do
    boundaries = Sourced::UI::Boundaries.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::REACTORS)
    context = Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path, :path_info).new({}, '/topology', '/topology'))
    html = described_class.new(boundaries:).call(context:)
    expect(html).to include('href="/topology/map?grouped=false&reads=true"',
                            %(data-effect="el.href = '/topology/map?grouped=' + $grouped + '&reads=' + $projections"))
    expect(html).not_to include('data-attr:href')
  end
end

RSpec.describe Sourced::UI::Dashboard::Components::ReactorPanel do
  let(:topology) { Sourced::Topology.build(SpecShop::REACTORS) }
  let(:boundaries) { Sourced::UI::Boundaries.build(topology, SpecShop::REACTORS) }
  let(:context) { Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path, :path_info).new({}, '/topology/map', '/topology/map')) }

  def render(group_id) = described_class.new(boundaries:, group_id:, topology:, reactors: SpecShop::REACTORS).call(context:)

  it "shows a machine's statechart and commands, what it dispatches by state, and who takes its events" do
    html = render(SpecShop::Shipment.group_id)
    expect(html).to include('id="reactor-panel"', 'kind-badge--machine', 'class="statechart"', 'Commands (2)',
                            'AddParcel', '→ shipping', 'href="/reactors/spec_shop.shipment"',
                            'Dispatches, by state (1 state)', '<code class="reactor-panel__group-name">shipping</code>',
                            '<dt>on AddParcel</dt>', 'starts SpecShop::Parcel',
                            'Its events are taken by 1 reactor', 'SpecShop::Parcel</span><span class="muted"> started, 1 event')
    expect(html).not_to include('display: none')
  end

  it "groups a machine's entry, timer and exit dispatches under each state" do
    alarm_topology = Sourced::Topology.build([SpecAlarm])
    alarm = Sourced::UI::Boundaries.build(alarm_topology, [SpecAlarm])
    html = described_class.new(boundaries: alarm, group_id: SpecAlarm.group_id, topology: alarm_topology, reactors: [SpecAlarm])
                          .call(context:)
    armed = html[%r{<code class="reactor-panel__group-name">armed</code>.*?</dl>}m]
    expect(armed).to include('<dt>on entry</dt>', '<dt>after computed</dt>', '<dt>on exit</dt>', 'Notify', 'SendSOS')
  end

  it "shows another reactor's event model, the events it takes and where from" do
    html = render(SpecShop::Checkout.group_id)
    expect(html).to include('class="event-model"', 'Events it takes (2)', 'from SpecShop::Orders',
                            'Dispatches, by what it reacts to (2 reactions)', 'on SpecShop::OrderPlaced',
                            '<dt>to SpecShop::Payments</dt>', 'SpecShop::ChargePayment')
    expect(render(SpecShop::Orders.group_id)).to include('SpecShop::PlaceOrder', '→ SpecShop::OrderPlaced')
  end

  it "lists a namespace's reactors, each opening its own panel" do
    html = render('spec_shop.*')
    expect(html).to include('kind-badge--namespace', '6 reactors',
                            %(data-on:click="$selected = &quot;spec_shop.orders&quot;; @get(&quot;/topology/map/panel?id=spec_shop.orders&quot;)"))
  end

  it 'starts empty and hidden' do
    html = described_class.empty.call(context:)
    expect(html).to include('id="reactor-panel"', 'display: none', %(data-show="$selected != ''"))
    expect(html).not_to include('<h2>')
  end
end

RSpec.describe Sourced::UI::Dashboard::Components::BoundaryMaps, 'full screen' do
  let(:boundaries) { Sourced::UI::Boundaries.build(Sourced::Topology.build(SpecShop::REACTORS), SpecShop::REACTORS) }
  let(:context) { Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path, :path_info).new({}, '/topology/map', '/topology/map')) }

  it 'has a click on a box open its panel, rather than its page, and light it' do
    html = described_class.new(boundaries:, full: true).call(context:)
    expect(html).to include('data-on:click__prevent="$selected = &quot;spec_shop.checkout&quot;; @get(',
                            %(data-class:is-selected="$selected == &quot;spec_shop.checkout&quot;"), 'id="reactor-panel"')
  end

  it 'leaves the Topology card following links' do
    html = described_class.new(boundaries:).call(context:)
    expect(html).not_to include('click__prevent', 'reactor-panel')
  end
end

RSpec.describe Sourced::UI::Dashboard::Components::MessageName do
  let(:context) { Struct.new(:request) { def url(path) = "/sourced#{path}" }.new(Struct.new(:env, :path).new({}, '/')) }

  it "renders a button that opens the layout's dialog beside it, and fetches the schema into it" do
    html = described_class.new(type: SpecShop::ChargePayment.type, kind: :command).call(context:)
    expect(html).to include('<button type="button" class="message-name bm-message bm-message--command"',
                            'data-indicator:message-schema-loading',
                            %(data-on:click="showMessageSchema(el); @get(&quot;/sourced/messages/schema?type=spec_shop.charge_payment&quot;)"),
                            '>SpecShop::ChargePayment</button>')
  end

  it 'declares the script that places the dialog, from the file beside it' do
    script = described_class.assets.find { it.name == 'messages/message_schema.js' }
    expect(File).to exist(script.path)
    expect(File.read(script.path)).to include('window.showMessageSchema')
  end

  it "is opened in the dashboard layout's popover" do
    html = Sourced::UI::Dashboard::Components::MessageSchema::Dialog.new.call(context:)
    expect(html).to include('id="message-schema"', 'popover="auto"', 'data-class:is-loading="$messageSchemaLoading"',
                            'id="message-schema-body"')
  end
end

RSpec.describe Sourced::UI::Dashboard::Components::MessageSchema do
  let(:context) { Struct.new(:request) { def url(path) = path }.new(Struct.new(:env, :path).new({}, '/')) }

  it "describes a message's payload attributes" do
    html = described_class.new(SpecShop::ChargePayment).call(context:)
    expect(html).to include('kind-badge--command', 'SpecShop::ChargePayment', 'spec_shop.charge_payment',
                            '<code class="message-schema__attr">order_id</code>', '<code class="message-schema__type">string</code>',
                            'required')
  end

  it "lists nested objects' and arrays' attributes after them, and descriptions" do
    payload = Class.new do
      def self.to_json_schema
        {
          'type' => 'object', 'required' => %w[address],
          'properties' => {
            'address' => { 'type' => 'object', 'required' => %w[city],
                           'properties' => { 'city' => { 'type' => 'string', 'description' => 'Where it ships' } } },
            'lines' => { 'type' => 'array', 'items' => { 'type' => 'object', 'properties' => { 'sku' => { 'type' => 'string' } } } },
            'vendor' => { 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'null' }] },
            'cents' => { 'type' => %w[integer null] }
          }
        }
      end
    end
    klass = Class.new(Sourced::Event) do
      def self.name = 'Shop::Shipped'
      def self.type = 'shop.shipped'
    end
    klass.const_set(:Payload, payload)

    html = described_class.new(klass).call(context:)
    rows = html.scan(%r{<code class="message-schema__attr">([^<]+)</code>}).flatten
    expect(rows).to eq(%w[address address.city lines lines[].sku vendor cents])
    # Nullable: its type, not null.
    expect(html).to include('<code class="message-schema__type">string</code><span class="message-schema__nullable">nullable</span>',
                            '<code class="message-schema__type">integer</code><span class="message-schema__nullable">nullable</span>')
    expect(html).to include('kind-badge--event', 'Where it ships', 'optional')
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'nokogiri'
require 'sourced/ui/components'
require_relative '../../../support/spec_trip'
require_relative '../../../support/spec_alarm'
require_relative '../../../support/spec_review'
require_relative '../../../support/machine_helpers'

RSpec.describe Sourced::UI::Components::Statechart do
  include MachineHelpers

  let(:keys) { { trip_id: 't1' } }

  def render(chart) = described_class.new(chart).call

  describe 'a definition' do
    subject(:svg) { render(SpecTrip.to_h) }

    it 'draws a parallel state with its regions side by side' do
      expect(svg).to match(/statechart__node--parallel" id="sc-planning"/)
      expect(svg).to include('id="sc-region-planning.flight"', 'id="sc-region-planning.hotel"')
      expect(svg).to include('id="sc-planning-flight-flight_chosen"', 'id="sc-planning-hotel-initial"')
    end

    it "draws a part's states inside its compound state, named for the part" do
      expect(svg).to match(/statechart__node--compound" id="sc-checkout"/)
      expect(svg).to include('id="sc-checkout-paying"', 'id="sc-checkout-paid"', '>Checkout<')
    end

    it 'draws finals, timers, joins and history targets' do
      expect(svg).to match(/statechart__node--final" id="sc-booked">.*statechart__final-ring/)
      expect(svg).to include('>⏱ 15m / Expire<')
      expect(svg).not_to include('statechart__timer')
      expect(svg).to include('>done<', '>on_final<', '>Replan (H*)<')
    end

    it 'lights nothing' do
      expect(svg).not_to include('is-active', 'is-live')
    end
  end

  it "lights an instance's active states, its done regions, and the commands it takes now" do
    trip = SpecTrip.new(keys)
    trip.evolve(decided(SpecTrip, keys, SpecTrip::Start.new(payload: keys), SpecTrip::ChooseFlight.new(payload: keys)))
    svg = render(trip.to_h)

    expect(svg).to match(/statechart__node--parallel is-active" id="sc-planning"/)
    expect(svg).to match(/statechart__node--final is-active" id="sc-planning-flight-flight_chosen"/)
    expect(svg).to match(/statechart__node--initial is-active" id="sc-planning-hotel-initial"/)
    expect(svg).to match(/statechart__region is-done" id="sc-region-planning.flight"/)
    expect(svg).not_to match(/is-active" id="sc-checkout/)

    live = svg.scan(/is-live"[^>]*><text[^>]*>([^<]+)</).flatten
    expect(live).to contain_exactly('Cancel', 'ChooseHotel')
    # Their lines too, with the live arrowhead.
    expect(svg.scan(/is-live"[^>]*><path[^>]*marker-end="url\(#sc-arrow-live\)"/).size).to eq(2)
    expect(svg).not_to match(/is-live"[^>]*><path[^>]*marker-end="url\(#sc-arrow\)"/)
  end

  describe 'a transition that starts child machines' do
    let(:chart) do
      state = ->(id, on = {}) { { id:, key: id, type: 'atomic', after: [], always: [], mounts: [], status: nil, on: } }
      log_in = { kind: 'command', event: 'spec.log_in', label: 'LogIn', targets: ['b'], starts: %w[app.session app.audit] }
      { machine: 'Spec', initial: 'a', states: { 'a' => state.('a', { 'log_in' => log_in }), 'b' => state.('b') } }
    end

    it 'links each machine it starts to its page, where href gives one' do
      svg = described_class.new(chart, href: ->(id) { "/reactors/#{id}" if id == 'app.session' }).call

      expect(svg).to include('LogIn / starts <a href="/reactors/app.session" class="statechart__link"><tspan>Session</tspan></a>, Audit</text>')
    end

    it 'says which, without links, given no href' do
      expect(described_class.new(chart).call).to include('>LogIn / starts Session, Audit</text>')
    end
  end

  # a: after 60s Ping (its own loop), after 2h Reset (b takes it), Go ─▶ b.
  describe 'timers' do
    subject(:svg) do
      state = ->(id, on = {}, after = []) { { id:, key: id, type: 'atomic', after:, always: [], mounts: [], status: nil, on: } }
      cmd = ->(label, targets) { { kind: 'command', event: "spec.#{label.downcase}", label:, targets:, starts: [] } }
      after = [{ delay: 60, dispatches: %w[spec.ping] }, { delay: '2h', dispatches: %w[spec.reset] }]
      render({ machine: 'Spec', initial: 'a', states: {
               'a' => state.('a', { 'spec.ping' => cmd.('Ping', []), 'spec.go' => cmd.('Go', ['b']) }, after),
               'b' => state.('b', { 'spec.reset' => cmd.('Reset', ['a']) })
             } })
    end

    it 'label the arrows they fire from their state' do
      expect(svg).to include('>⏱ 60s / Ping<', '>Go<', '>Reset<')
    end

    it "go on the state when another state takes their commands" do
      expect(svg).to match(%r{class="statechart__timer"[^>]*>⏱ 2h / Reset</text>})
    end
  end

  describe 'a machine with actions and a computed timer' do
    let(:alarm) { SpecAlarm }

    it 'labels the timer by what computes its delay' do
      expect(render(alarm.to_h)).to include('>⏱ computed / SendSOS<')
    end

    it 'draws a state’s entry and exit actions under its name, the box grown to fit them' do
      svg = Nokogiri::XML(render(alarm.to_h))
      armed = svg.at_css('#sc-armed')
      disarmed = svg.at_css('#sc-disarmed')

      expect(armed.css('.statechart__action').map(&:text)).to eq(['entry / Notify', 'exit / Notify'])
      expect(armed.at_css('.statechart__rule')).not_to be_nil
      expect(armed.at_css('rect')['height'].to_f).to be > disarmed.at_css('rect')['height'].to_f
      expect(disarmed.css('.statechart__action')).to be_empty
    end

    it 'names another machine’s command it dispatches in full, and leaves out an action that dispatches nothing' do
      chart = Marshal.load(Marshal.dump(alarm.to_h))
      armed = chart[:states].values.find { it[:key].to_s == 'armed' }
      armed[:entry] = [{ dispatches: ['billing.charge_card', 'spec_alarm.notify'], optional: true }]
      armed[:exit] = [{ dispatches: [], optional: true }]

      actions = Nokogiri::XML(render(chart)).css('#sc-armed .statechart__action').map(&:text)
      # Not registered here: its type. One registered, its class's name.
      expect(actions).to eq(['entry / billing.charge_card, Notify'])
    end

    it 'links each command an action dispatches where command_href says, and leaves the rest as text' do
      chart = Marshal.load(Marshal.dump(alarm.to_h))
      armed = chart[:states].values.find { it[:key].to_s == 'armed' }
      armed[:entry] = [{ dispatches: ['billing.charge_card', 'spec_alarm.notify'], optional: true }]
      command_href = ->(type) { "/reactors/billing" if type == 'billing.charge_card' }

      entry = Nokogiri::XML(described_class.new(chart, command_href:).call).css('#sc-armed .statechart__action').first
      link = entry.at_css('a.statechart__link')
      expect(entry.text).to eq('entry / billing.charge_card, Notify')
      expect(link['href']).to eq('/reactors/billing')
      expect(link.text).to eq('billing.charge_card')
      expect(entry.css('a').size).to eq(1)
    end

    it 'names a registered command of another machine by its class' do
      chart = Marshal.load(Marshal.dump(SpecLight.to_h))
      state = chart[:states].values.find { it[:type] == 'atomic' }
      state[:entry] = [{ dispatches: [SpecAlarm::SendSOS.type], optional: false }]

      actions = Nokogiri::XML(render(chart)).css('.statechart__action').map(&:text)
      expect(actions).to eq(['entry / SpecAlarm::SendSOS'])
    end

    it 'maps each command to the reactor that handles it' do
      handlers = Sourced::UI::MachineChart.command_handlers([alarm])
      expect(handlers).to include('spec_alarm.notify' => alarm.group_id, 'spec_alarm.send_sos' => alarm.group_id)
    end

    it "slices a state with actions from the machine's topology" do
      slice = Sourced::UI::MachineSlice.build(alarm, 'armed', Sourced::Topology.build([alarm]))
      expect(slice.nodes.map(&:name)).to include('SpecAlarm::Armed', 'SpecAlarm::Disarm')
    end
  end

  # Edges can route around the outside of the boxes laid out: the drawing is
  # as big as what's in it, so none is cut off at its edge.
  it 'fits every line and label it draws inside its view' do
    [SpecTrip, SpecAlarm, SpecReview].each do |machine|
      svg = Nokogiri::XML(render(machine.to_h))
      root = svg.root
      x, y, w, h = root['viewBox'].split.map(&:to_f)
      points = root.css('path[d]').flat_map { it['d'].scan(/-?\d+(?:\.\d+)?/).map(&:to_f).each_slice(2).to_a }
      points += root.css('text[x][y]').map { [it['x'].to_f, it['y'].to_f] }

      expect(points).to all(satisfy { |px, py| px.between?(x, x + w) && py.between?(y, y + h) }), machine.name
      expect([root['width'].to_i, root['height'].to_i]).to eq([w.round, h.round])
    end
  end

  it 'stacks the labels of edges that share a line, rather than drawing them over each other' do
    chart = described_class.new(SpecAlarm.to_h)
    edge = ->(label) { described_class::Edge.new(from: 'a', to: 'b', label:, kind: :command) }
    line = 'M 0 10 L 100 10'
    stacked = chart.send(:stack_labels, [[edge.('Complete'), [line, [50, 5, 'middle']]],
                                         [edge.('Fail'), [line, [50, 5, 'middle']]],
                                         [edge.('Other'), ['M 0 90 L 100 90', [50, 85, 'middle']]]])

    expect(stacked.map { |e, (_, (x, y, _))| [e.label, x, y] })
      .to eq([['Complete', 50, 5], ['Fail', 50, 5 - (described_class::LABEL_H + 2)], ['Other', 50, 85]])
  end

  it 'widens its view to an edge routed outside the boxes, and to its label' do
    chart = described_class.new(SpecAlarm.to_h)
    root = Struct.new(:x, :y, :right, :bottom).new(0, 0, 200, 100)
    edge = described_class::Edge.new(from: 'a', to: 'b', label: 'Rescan', kind: :command)
    # Out to the left and below the boxes: the line's lowest point sets the
    # bottom, its label (ending at x -30) the left.
    drawing = ['M 10 50 C -60 50, -60 160, 10 130', [-30, 145, 'end']]

    x1, y1, x2, y2 = chart.send(:bounds, root, [[edge, drawing]])
    expect(x1).to eq(-30 - 'Rescan'.length * described_class::EDGE_CHAR_W) # -66, past the line's -60
    expect([y1, x2, y2]).to eq([0, 200, 160])
  end

  it 'draws a chart with nothing in it' do
    expect(render({ machine: 'Empty', initial: nil, states: {} })).to include('<svg', 'Empty statechart')
  end

  # p is parallel, with one region r: initial ─Go─▶ x, and x ─Reset─▶ p.
  it "re-enters a parallel checkpoint from inside it at the start of the region it's in" do
    state = ->(id, type, on = {}) { { id:, key: id.split('.').last, type:, after: [], on:, always: [], mounts: [], status: nil } }
    cmd = ->(label, target) { { kind: 'command', event: "spec.#{label.downcase}", label:, targets: [target], starts: [] } }
    region = { id: 'p.r', key: 'r', initial: 'p.r.initial', states: {
      'initial' => state.('p.r.initial', 'initial', { 'go' => cmd.('Go', 'p.r.x') }),
      'x' => state.('p.r.x', 'atomic', { 'reset' => cmd.('Reset', 'p') })
    } }
    chart = { machine: 'Spec', initial: 'p', states: { 'p' => state.('p', 'parallel').merge(states: { 'r' => region }) } }
    svg = Nokogiri::XML(render(chart))
    svg.remove_namespaces!

    # Reset reaches the region's initial position, not p itself, so no line
    # goes to p's border.
    reset = svg.xpath('//g[@data-from="p.r.x"]')
    expect(reset.map { it['data-to'] }.uniq).to eq(['p.r.initial'])
    expect(reset.map { it.text.strip }).to include('Reset')
    expect(svg.xpath('//g[@data-to="p"]')).to be_empty

    # And its line ends on that initial dot.
    dot = svg.at_xpath('//g[@id="sc-p-r-initial"]/circle')
    *, x, y = reset.at_xpath('path')['d'].scan(/-?[\d.]+/).map(&:to_f)
    expect(Math.hypot(x - dot['cx'].to_f, y - dot['cy'].to_f)).to be <= dot['r'].to_f + 0.5
  end

  # A part escalating into a parallel checkpoint's history (see SpecReview).
  it "draws a part's on_final escalation to a history target at its checkpoint" do
    svg = Nokogiri::XML(render(SpecReview.to_h))
    svg.remove_namespaces!
    escalation = svg.xpath('//g[@data-from="scanning.scanned"]')
    expect(escalation.map { it['data-to'] }.uniq).to eq(['reviewing'])
    expect(escalation.text).to include('on_final (H)')
  end
end

RSpec.describe Sourced::UI::MachineChart do
  let(:chart) { SpecTrip.to_h }

  it 'lists every state, depth first, with the commands it takes and those it inherits' do
    rows = described_class.rows(chart).to_h { [it.path, it] }

    expect(rows.keys).to eq(%w[
      initial planning planning.flight.initial planning.flight.flight_chosen planning.hotel.initial
      planning.hotel.hotel_chosen checkout checkout.paying checkout.paid checkout.expired booked cancelled
    ])
    expect(rows['planning.flight.initial'].own.map { it[:label] }).to eq(%w[ChooseFlight])
    expect(rows['planning.flight.initial'].inherited.map { it[:label] }).to eq(%w[Cancel])
    expect(rows['checkout.paying'].timers).to eq([described_class::Timer.new(delay: '15m', commands: %w[Expire])])
    expect(rows['checkout.paying'].timers.first.label).to eq('15m / Expire')
  end

  it "finds the commands a sibling region's states take" do
    siblings = described_class.sibling_regions(chart, 'planning.flight.initial')

    expect(siblings.map { [it[0], it[1].map { |t| t[:label] }] }).to eq([['planning.hotel', %w[ChooseHotel]]])
  end

  it 'lights a state and the states enclosing it' do
    svg = Sourced::UI::Components::Statechart.new(described_class.highlight(chart, 'checkout.paying')).call

    expect(svg).to match(/is-active" id="sc-checkout"/)
    expect(svg).to match(/is-active" id="sc-checkout-paying"/)
    expect(svg).not_to match(/is-active" id="sc-planning"/)
    expect(svg).to match(/is-live"[^>]*><text[^>]*>Pay</)
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'nokogiri'
require 'sourced/ui/components'
require_relative '../../../support/spec_trip'
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

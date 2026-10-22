# frozen_string_literal: true

require 'spec_helper'
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
      expect(svg).to include('>⏱ 15m<')
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

    live = svg.scan(/is-live"><text[^>]*>([^<]+)</).flatten
    expect(live).to contain_exactly('Cancel', 'ChooseHotel')
    # Their lines too, with the live arrowhead.
    expect(svg.scan(/is-live"><path[^>]*marker-end="url\(#sc-arrow-live\)"/).size).to eq(2)
    expect(svg).not_to match(/is-live"><path[^>]*marker-end="url\(#sc-arrow\)"/)
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
    statechart = described_class.new(chart)

    reset = statechart.instance_variable_get(:@placed).fetch([:region, 'p.r']).find { it.edge.label == 'Reset' }
    expect(reset.to).to eq('p.r.initial')
    expect(statechart.instance_variable_get(:@direct)).to be_empty
    expect(statechart.call).to include('>Reset<')
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
    expect(rows['checkout.paying'].timers).to eq(['15m'])
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
    expect(svg).to match(/is-live"><text[^>]*>Pay</)
  end
end

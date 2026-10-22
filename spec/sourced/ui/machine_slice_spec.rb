# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'
require_relative '../../support/spec_trip'
require_relative '../../support/spec_light'

RSpec.describe Sourced::UI::MachineSlice do
  let(:topology) { Sourced::Topology.build([SpecTrip]) }

  def slice(path) = described_class.build(SpecTrip, path, topology)
  def named(flow, name) = flow.nodes.find { it.name.end_with?("::#{name}") || it.name == name }

  it "takes the commands a state accepts, its own and its enclosing states', and nothing else of the machine" do
    flow = slice('checkout.paying')
    commands = flow.nodes.select { it.kind == :command }.map { it.name.split('::').last }

    expect(commands).to contain_exactly('Pay', 'Expire', 'Cancel', 'Replan')
  end

  it 'draws the state changes a command can make from here as events' do
    flow = slice('checkout.paying')
    events = flow.nodes.select { it.kind == :event }.map { it.name.split('::').last }
    pay = named(flow, 'Pay')

    expect(events).to include('Paid', 'Cancelled', 'Planning')
    # Pay moves to paid from here; booked follows only through on_final, not from Pay itself.
    expect(flow.edges.map { [it.from, it.to] }).to include([pay.id, 'spec_trip.runtime.checkout.paid'])
    expect(pay.tags).to eq([])
  end

  it 'tags a command that may leave the machine where it is' do
    light = Sourced::UI::MachineSlice.build(SpecLight, 'on', Sourced::Topology.build([SpecLight]))

    expect(named(light, 'Dim').tags).to eq(['stays'])
    expect(named(light, 'Toggle').tags).to eq([])
  end

  it "starts at the state's own event when entering it sets off an automation" do
    flow = slice('checkout.paying')
    timer = flow.nodes.find { it.kind == :automation }

    expect(timer.name).to eq('actions(checkout.paying)')
    expect(flow.nodes.first.name).to eq('SpecTrip::Checkout::Paying')
    expect(flow.edges.map { [it.from, it.to] }).to include([timer.id, 'spec_trip.checkout.expire'])
  end

  it "doesn't take what the state's sibling regions accept" do
    flow = slice('planning.flight.initial')
    commands = flow.nodes.select { it.kind == :command }.map { it.name.split('::').last }

    expect(commands).to contain_exactly('ChooseFlight', 'Cancel')
  end

  it "starts with how the machine gets into the state: its own event, after what appends it, not followed" do
    light = Sourced::UI::MachineSlice.build(SpecLight, 'broken', Sourced::Topology.build([SpecLight]))
    first, second = light.nodes.first(2)

    expect([first.name, first.own]).to eq(['SpecLight::Break', false])
    expect([second.name, second.own]).to eq(['SpecLight::Broken', true])
    # Break's other moves aren't followed: broken accepts nothing.
    expect(light.nodes.map(&:name)).not_to include('SpecLight::Toggle', 'SpecLight::On', 'SpecLight::Off')
  end

  it "starts an initial position's slice at its commands: it has no event of its own" do
    light = Sourced::UI::MachineSlice.build(SpecLight, 'initial', Sourced::Topology.build([SpecLight]))

    expect(light.nodes.map { [it.name, it.own] }).to eq([['SpecLight::Install', true], ['SpecLight::Off', true]])
  end

  it 'refuses a state the machine has not got' do
    expect { slice('nope') }.to raise_error(ArgumentError, /no state "nope"/)
  end
end

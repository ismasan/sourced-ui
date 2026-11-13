# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'
require_relative '../../support/spec_light'
require_relative '../../support/machine_helpers'

RSpec.describe Sourced::UI::MachineTimeline do
  include MachineHelpers

  let(:keys) { { light_id: 'l1' } }

  # Commands then what they appended, positioned as the store would.
  let(:messages) do
    install, toggle, dim = [SpecLight::Install, SpecLight::Toggle, SpecLight::Dim].map { it.new(payload: keys) }
    off, on, dimmed = decided(SpecLight, keys, install, toggle, dim)
    [install, off, toggle, on, dim, dimmed].each_with_index.map { |m, i| Sourced::PositionedMessage.new(m, i + 10) }
  end

  subject(:timeline) { described_class.new(SpecLight, keys, messages) }

  it "reads the types the machine handles, evolves from and defines, its own events too" do
    expect(described_class.message_types(SpecLight).map(&:type)).to include(
      'spec_light.install', 'spec_light.dim', 'spec_light.runtime.on', 'spec_light.dimmed'
    )
  end

  it 'records where the machine is after each message, and which moved it' do
    expect(timeline.steps.map(&:paths)).to eq([[], ['off'], ['off'], ['on'], ['on'], ['on']])
    expect(timeline.steps.map(&:moved?)).to eq([false, true, false, true, false, false])
    expect(timeline.steps.map(&:entered)).to eq([[], ['off'], [], ['on'], [], []])
    expect(timeline.last_position).to eq(15)
  end

  it 'gives the instance as it was at a log position' do
    expect(timeline.at(11).machine.paths).to eq(['off'])
    expect(timeline.at(12).machine.paths).to eq(['off'])
    expect(timeline.at(9).machine.paths).to eq([])
    expect(timeline.at.machine.paths).to eq(['on'])
  end

  describe '#groups' do
    # As appended by Sourced.handle!: each command's events caused by it,
    # with one appended for no command in the partition.
    let(:messages) do
      install, toggle = [SpecLight::Install, SpecLight::Toggle].map { it.new(payload: keys) }
      off, on = decided(SpecLight, keys, install, toggle)
      [install, install.correlate(off), SpecLight::Dimmed.new(payload: keys), toggle, toggle.correlate(on)]
        .each_with_index.map { |m, i| Sourced::PositionedMessage.new(m, i + 10) }
    end

    it 'groups its steps by the command each was appended for, in log order' do
      groups = timeline.groups
      expect(groups.map { it.command&.position }).to eq([10, nil, 13])
      expect(groups.map { it.steps.map(&:position) }).to eq([[10, 11], [12], [13, 14]])
      expect(groups.map(&:position)).to eq([10, 12, 13])
    end
  end

  it 'finds the step at or before a position' do
    expect(timeline.step_at(12).position).to eq(12)
    expect(timeline.step_at(100).position).to eq(15)
    expect(timeline.step_at(9)).to be_nil
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/components'
require_relative '../../../support/spec_light'

RSpec.describe Sourced::UI::Components::Statechart do
  def render(chart) = described_class.new(chart).call

  it 'draws the definition, with nothing active' do
    svg = render(SpecLight.to_h)

    expect(svg).to include('id="sc-off"', 'id="sc-on"', 'id="sc-broken"', '>Toggle<', '>Dim<')
    expect(svg).to include('statechart__node--final')
    expect(svg).not_to include('is-active')
  end

  it 'lights a highlighted state and the commands it takes' do
    svg = render(Sourced::UI::MachineChart.highlight(SpecLight.to_h, 'on'))

    expect(svg).to match(/statechart__node--atomic is-active" id="sc-on"/)
    expect(svg).not_to match(/is-active" id="sc-off"/)
    expect(svg).to match(/statechart__edge--data_live is-live"><path[^>]*><\/path><text[^>]*>Dim</)
  end
end

RSpec.describe Sourced::UI::MachineChart do
  it 'lists states with the commands each takes' do
    rows = described_class.rows(SpecLight.to_h)

    expect(rows.map(&:path)).to eq(%w[initial off on broken])
    expect(rows.find { it.path == 'on' }.own.map { it[:label] }).to eq(%w[Toggle Dim Break])
  end
end

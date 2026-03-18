# frozen_string_literal: true

require 'spec_helper'
require 'nokogiri'

require 'sourced/ui/components'

RSpec.describe Sourced::UI::Components::MessageFilter do
  FilterTestEvent = Sourced::CCC::Event.define('test.thing_created') do
    attribute :name, String
    attribute :amount, Integer
  end unless defined?(FilterTestEvent)

  FilterTestCommand = Sourced::CCC::Command.define('test.create_thing') do
    attribute :title, String
  end unless defined?(FilterTestCommand)

  def render(component)
    component.call
  end

  def parse(html)
    Nokogiri::HTML.fragment(html)
  end

  describe 'filter rows' do
    it 'renders a row for each message in filters' do
      filters = { FilterTestEvent => {}, FilterTestCommand => {} }
      html = render(described_class.new(filters:))
      doc = parse(html)

      rows = doc.css('.message-filter__row')
      expect(rows.size).to eq(2)
    end

    it 'renders the message type as label' do
      filters = { FilterTestEvent => {} }
      html = render(described_class.new(filters:))
      doc = parse(html)

      label = doc.at_css('.message-filter__row label')
      expect(label.text).to eq('test.thing_created')
    end

    it 'renders text inputs for each payload attribute' do
      filters = { FilterTestEvent => {} }
      html = render(described_class.new(filters:))
      doc = parse(html)

      inputs = doc.css('.message-filter__row input[type="text"]')
      expect(inputs.size).to eq(2)
      expect(inputs[0]['name']).to eq('filters[test.thing_created][name]')
      expect(inputs[1]['name']).to eq('filters[test.thing_created][amount]')
    end

    it 'pre-fills input values from filters hash' do
      filters = { FilterTestEvent => { name: 'foo', amount: '42' } }
      html = render(described_class.new(filters:))
      doc = parse(html)

      inputs = doc.css('.message-filter__row input[type="text"]')
      expect(inputs[0]['value']).to eq('foo')
      expect(inputs[1]['value']).to eq('42')
    end

    it 'separates rows with hr elements' do
      filters = { FilterTestEvent => {}, FilterTestCommand => {} }
      html = render(described_class.new(filters:, available: []))
      doc = parse(html)

      hrs = doc.css('form hr')
      expect(hrs.size).to eq(1)
    end
  end

  describe 'available messages dropdown' do
    it 'renders a select with available message types' do
      html = render(described_class.new(available: [FilterTestEvent, FilterTestCommand]))
      doc = parse(html)

      options = doc.css('select[name="add_filter"] option')
      expect(options.size).to eq(2)
      expect(options[0]['value']).to eq('test.thing_created')
      expect(options[1]['value']).to eq('test.create_thing')
    end

    it 'renders an add button' do
      html = render(described_class.new(available: [FilterTestEvent]))
      doc = parse(html)

      button = doc.at_css('button')
      expect(button.text).to eq('Add')
    end

    it 'does not render dropdown when available is empty' do
      html = render(described_class.new(filters: { FilterTestEvent => {} }, available: []))
      doc = parse(html)

      expect(doc.at_css('select')).to be_nil
      expect(doc.at_css('button')).to be_nil
    end
  end
end

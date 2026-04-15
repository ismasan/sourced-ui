# frozen_string_literal: true

require 'spec_helper'
require 'nokogiri'

require 'sourced/ui/components'

RSpec.describe Sourced::UI::Components::MessageFilter do
  FilterTestEvent = Sourced::Event.define('test.thing_created') do
    attribute :name, String
    attribute :amount, Integer
  end unless defined?(FilterTestEvent)

  FilterTestCommand = Sourced::Command.define('test.create_thing') do
    attribute :title, String
  end unless defined?(FilterTestCommand)

  def render(component)
    component.call
  end

  def parse(html)
    Nokogiri::HTML.fragment(html)
  end

  def filter_entry(type, attributes = {})
    { type: type, attributes: attributes }
  end

  it 'wraps content in a div with id message-filter' do
    html = render(described_class.new(available: [FilterTestEvent]))
    doc = parse(html)

    wrapper = doc.at_css('div#message-filter')
    expect(wrapper).not_to be_nil
    expect(wrapper.at_css('form')).not_to be_nil
  end

  describe 'filter rows' do
    it 'renders a row for each filter entry' do
      filters = [filter_entry(FilterTestEvent), filter_entry(FilterTestCommand)]
      html = render(described_class.new(filters:))
      doc = parse(html)

      rows = doc.css('.message-filter__row')
      expect(rows.size).to eq(2)
    end

    it 'renders the message type as label' do
      filters = [filter_entry(FilterTestEvent)]
      html = render(described_class.new(filters:))
      doc = parse(html)

      type_label = doc.at_css('.message-filter__type span')
      expect(type_label.text).to eq('test.thing_created')
    end

    it 'renders text inputs for each payload attribute' do
      filters = [filter_entry(FilterTestEvent)]
      html = render(described_class.new(filters:))
      doc = parse(html)

      inputs = doc.css('.message-filter__row input[type="text"]')
      expect(inputs.size).to eq(2)
      expect(inputs[0]['name']).to eq('filters[0][attributes][name]')
      expect(inputs[1]['name']).to eq('filters[0][attributes][amount]')
    end

    it 'renders a hidden type field per filter entry' do
      filters = [filter_entry(FilterTestEvent), filter_entry(FilterTestCommand)]
      html = render(described_class.new(filters:))
      doc = parse(html)

      hidden = doc.css('input[type="hidden"]')
      expect(hidden.size).to eq(2)
      expect(hidden[0]['name']).to eq('filters[0][type]')
      expect(hidden[0]['value']).to eq('test.thing_created')
      expect(hidden[1]['name']).to eq('filters[1][type]')
      expect(hidden[1]['value']).to eq('test.create_thing')
    end

    it 'pre-fills input values from filter attributes' do
      filters = [filter_entry(FilterTestEvent, 'name' => 'foo', 'amount' => '42')]
      html = render(described_class.new(filters:))
      doc = parse(html)

      inputs = doc.css('.message-filter__row input[type="text"]')
      expect(inputs[0]['value']).to eq('foo')
      expect(inputs[1]['value']).to eq('42')
    end

    it 'allows duplicate message types with different values' do
      filters = [
        filter_entry(FilterTestEvent, 'name' => 'foo'),
        filter_entry(FilterTestEvent, 'name' => 'bar')
      ]
      html = render(described_class.new(filters:))
      doc = parse(html)

      rows = doc.css('.message-filter__row')
      expect(rows.size).to eq(2)

      inputs = doc.css('input[type="text"]')
      name_inputs = inputs.select { |i| i['name'].include?('[name]') }
      expect(name_inputs[0]['value']).to eq('foo')
      expect(name_inputs[1]['value']).to eq('bar')
    end

    it 'separates rows with hr elements' do
      filters = [filter_entry(FilterTestEvent), filter_entry(FilterTestCommand)]
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

    it 'renders add button with Datastar post action when action is provided' do
      html = render(described_class.new(available: [FilterTestEvent], action: '/log/filters/add'))
      doc = parse(html)

      button = doc.at_css('button')
      expect(button.text).to eq('Add')
      expect(button['data-on:click']).to include("@post('/log/filters/add'")
      expect(button['data-on:click']).to include('contentType')
    end

    it 'renders add button without Datastar action when action is nil' do
      html = render(described_class.new(available: [FilterTestEvent], action: nil))
      doc = parse(html)

      button = doc.at_css('button')
      expect(button['data-on:click']).to be_nil
    end

    it 'does not render dropdown when available is empty' do
      html = render(described_class.new(filters: [filter_entry(FilterTestEvent)], available: []))
      doc = parse(html)

      expect(doc.at_css('select')).to be_nil
      expect(doc.at_css('button')).to be_nil
    end
  end

  describe 'submit button' do
    it 'renders a GET form with the submit URL as action' do
      filters = [filter_entry(FilterTestEvent)]
      html = render(described_class.new(filters:, submit: '/log'))
      doc = parse(html)

      form = doc.at_css('form')
      expect(form['action']).to eq('/log')
      expect(form['method']).to eq('get')
    end

    it 'renders apply button when filters and submit URL are present' do
      filters = [filter_entry(FilterTestEvent)]
      html = render(described_class.new(filters:, submit: '/log'))
      doc = parse(html)

      button = doc.at_css('.message-filter__submit button')
      expect(button).not_to be_nil
      expect(button.text).to eq('Apply filters')
      expect(button['type']).to eq('submit')
    end

    it 'does not render apply button when no filters' do
      html = render(described_class.new(filters: [], submit: '/log/filters/apply'))
      doc = parse(html)

      expect(doc.at_css('.message-filter__submit')).to be_nil
    end

    it 'does not render apply button when submit URL is nil' do
      filters = [filter_entry(FilterTestEvent)]
      html = render(described_class.new(filters:, submit: nil))
      doc = parse(html)

      expect(doc.at_css('.message-filter__submit')).to be_nil
    end
  end

  describe 'parsing filter entries' do
    it 'accepts message type as string (resolved via registry)' do
      filters = [{ type: 'test.thing_created', attributes: { 'name' => 'foo' } }]
      html = render(described_class.new(filters:))
      doc = parse(html)

      type_label = doc.at_css('.message-filter__type span')
      expect(type_label.text).to eq('test.thing_created')
    end

    it 'accepts symbol-keyed hashes' do
      filters = [{ type: FilterTestEvent, attributes: { 'name' => 'foo' } }]
      html = render(described_class.new(filters:))
      doc = parse(html)

      type_label = doc.at_css('.message-filter__type span')
      expect(type_label.text).to eq('test.thing_created')
    end
  end
end

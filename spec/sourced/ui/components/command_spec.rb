# frozen_string_literal: true

require 'spec_helper'
require 'nokogiri'

require 'sourced/ui/components'

RSpec.describe Sourced::UI::Components::Command do
  TestCommand = Sourced::Command.define('test.create_thing') do
    attribute :name, String
  end unless defined?(TestCommand)

  def render(component, &block)
    component.call(&block)
  end

  def parse(html)
    Nokogiri::HTML.fragment(html)
  end

  describe 'default rendering' do
    it 'renders a form with hidden type and cid fields' do
      html = render(described_class.new(TestCommand)) { 'content' }
      doc = parse(html)

      form = doc.at_css('form')
      expect(form).not_to be_nil

      type_input = form.at_css('input[name="command[type]"]')
      expect(type_input['value']).to eq('test.create_thing')

      cid_input = form.at_css('input[name="command[_cid]"]')
      expect(cid_input).not_to be_nil
      expect(cid_input['value']).to match(/^cmd/)
    end

    it 'does not render a stream_id hidden field' do
      html = render(described_class.new(TestCommand)) { 'content' }
      doc = parse(html)

      stream_id_input = doc.at_css('input[name="command[stream_id]"]')
      expect(stream_id_input).to be_nil
    end

    it 'defaults to AJAX post on submit' do
      html = render(described_class.new(TestCommand)) { 'content' }
      doc = parse(html)

      form = doc.at_css('form')
      expect(form['data-on:submit']).to include("@post('/commands'")
      expect(form['data-indicator-fetching']).not_to be_nil
    end
  end

  describe 'custom href' do
    it 'posts to the specified URL' do
      html = render(described_class.new(TestCommand, href: '/my-endpoint')) { 'content' }
      doc = parse(html)

      form = doc.at_css('form')
      expect(form['data-on:submit']).to include("@post('/my-endpoint'")
    end
  end

  describe 'non-AJAX mode' do
    it 'renders a standard form with action and method' do
      html = render(described_class.new(TestCommand, ajax: false, href: '/submit')) { 'content' }
      doc = parse(html)

      form = doc.at_css('form')
      expect(form['action']).to eq('/submit')
      expect(form['method']).to eq('post')
      expect(form['data-on:submit']).to be_nil
    end
  end

  describe 'form field helpers' do
    it '#text_field renders input with error wrapper' do
      component = described_class.new(TestCommand)
      html = render(component) { component.text_field(:name, placeholder: 'Enter name') }
      doc = parse(html)

      wrapper = doc.at_css('.command-field')
      expect(wrapper).not_to be_nil

      input = wrapper.at_css('input[type="text"]')
      expect(input['name']).to eq('command[payload][name]')
      expect(input['placeholder']).to eq('Enter name')

      errors = wrapper.at_css('.command-field__errors')
      expect(errors).not_to be_nil
    end

    it '#number_field renders number input with error wrapper' do
      component = described_class.new(TestCommand)
      html = render(component) { component.number_field(:amount, min: '0') }
      doc = parse(html)

      input = doc.at_css('input[type="number"]')
      expect(input['name']).to eq('command[payload][amount]')
      expect(input['min']).to eq('0')
    end

    it '#check_box renders checkbox input with error wrapper' do
      component = described_class.new(TestCommand)
      html = render(component) { component.check_box(:active) }
      doc = parse(html)

      input = doc.at_css('input[type="checkbox"]')
      expect(input['name']).to eq('command[payload][active]')
    end

    it '#payload_fields renders hidden inputs' do
      component = described_class.new(TestCommand)
      html = render(component) { component.payload_fields(name: 'foo', other: 'bar') }
      doc = parse(html)

      name_input = doc.at_css('input[name="command[payload][name]"]')
      expect(name_input['type']).to eq('hidden')
      expect(name_input['value']).to eq('foo')

      other_input = doc.at_css('input[name="command[payload][other]"]')
      expect(other_input['value']).to eq('bar')
    end
  end

  describe 'custom events' do
    it 'binds to specified event instead of submit' do
      html = render(described_class.new(TestCommand, on: 'change')) { 'content' }
      doc = parse(html)

      form = doc.at_css('form')
      expect(form['data-on:change']).to include("@post('/commands'")
      expect(form['data-on:submit']).to be_nil
    end
  end

  describe Sourced::UI::Components::Command::ErrorMessages do
    it 'renders error span with field-specific ID' do
      html = described_class.new('cmd123-name', ['is required', 'too short']).call
      doc = parse(html)

      span = doc.at_css('span.command-field__errors')
      expect(span['id']).to eq('cmd123-name-errors')
      expect(span.text).to eq('is required, too short')
    end

    it 'renders empty when no errors' do
      html = described_class.new('cmd123-name').call
      doc = parse(html)

      span = doc.at_css('span.command-field__errors')
      expect(span.text).to eq('')
    end
  end
end

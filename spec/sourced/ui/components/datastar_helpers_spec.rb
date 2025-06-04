# frozen_string_literal: true

require 'spec_helper'

require 'sourced/ui/components'

RSpec.describe Sourced::UI::Components::DatastarHelpers do
  subject(:component_class) do
    Class.new do
      include Sourced::UI::Components::DatastarHelpers
    end
  end

  specify 'on.submit.get' do
    component = component_class.new
    spec = component._d.on.submit.get('/sourced/correlation', content_type: 'form')

    expect(spec.to_h).to eq({
      'on-submit' => %(@get('/sourced/correlation', {contentType: 'form'})),
    })
  end

  specify 'on.submit.post' do
    component = component_class.new
    spec = component._d.on.submit.post('/sourced/correlation', content_type: 'form')

    expect(spec.to_h).to eq({
      'on-submit' => %(@post('/sourced/correlation', {contentType: 'form'})),
    })
  end

  specify 'signals' do
    component = component_class.new
    spec = component._d.signals(fooBar: 1)

    expect(spec.to_h).to eq({
      signals: '{"fooBar":1}'
    })
  end

  specify 'composing' do
    component = component_class.new
    spec1 = component._d.on.submit.get('/sourced/correlation', content_type: 'form')
    spec2 = spec1.on.click.post('/sourced/foo')
    spec3 = spec2.signals(fooBar: 1)

    expect(spec1.to_h).to eq({
      'on-submit' => %(@get('/sourced/correlation', {contentType: 'form'}))
    })

    expect(spec2.to_h).to eq({
      'on-submit' => %(@get('/sourced/correlation', {contentType: 'form'})),
      'on-click' => %(@post('/sourced/foo')),
    })

    expect(spec3.to_h).to eq({
      'on-submit' => %(@get('/sourced/correlation', {contentType: 'form'})),
      'on-click' => %(@post('/sourced/foo')),
      signals: '{"fooBar":1}'
    })
  end

  specify 'on.click.run' do
    component = component_class.new
    spec = component._d.on.click.run('a = b')

    expect(spec.to_h).to eq({
      'on-click' => %(a = b),
    })
  end

  %i[
      click
      dblclick
      mousedown
      mouseup
      mouseover
      mouseout
      mousemove
      mouseenter
      mouseleave
      contextmenu
      keydown
      keyup
      keypress
      submit
      reset
      change
      input
      focus
      blur
  ].each do |event|
    specify "on.#{event}.get" do
      component = component_class.new
      spec = component._d.on.send(event).get('/sourced/correlation')

      expect(spec.to_h).to eq({
        "on-#{event}" => %(@get('/sourced/correlation')),
      })
    end
  end
end

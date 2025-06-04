# frozen_string_literal: true

require 'spec_helper'

require 'sourced/ui/components'

RSpec.describe Sourced::UI::Components::DatastarHelpers do
  subject(:component_class) do
    Class.new do
      include Sourced::UI::Components::DatastarHelpers
    end
  end

  it "does something useful" do
    component = component_class.new
    
    spec = component._d.on.submit.get('/sourced/correlation', content_type: 'form')

    expect(spec.to_h).to eq({
      'on-submit' => %(@get('/sourced/correlation', {contentType: 'form'})),
    })
  end
end

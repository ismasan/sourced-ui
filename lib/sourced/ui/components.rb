# frozen_string_literal: true

require 'phlex'

module Sourced
  module UI
    module Components
      extend Phlex::Kit
    end
  end
end

require_relative 'components/component'
require_relative 'components/command'

# frozen_string_literal: true

require 'sourced/ui/dashboard/app'

module Sourced
  module UI
    module Dashboard
      def self.call(env) = App.call(env)
    end
  end
end

# frozen_string_literal: true

require 'sourced/ui/dashboard/app'

module Sourced
  module UI
    module Dashboard
      class Configuration
        Link = Sourced::Types::Data[
          label: String, 
          href: String, 
          url: Sourced::Types::Boolean.default(true)
        ]

        Links = Sourced::Types::Array[Link]

        def initialize
          @header_links = []
        end

        def header_links(links = nil)
          return @header_links unless links

          @header_links = Links.parse(links)
        end
      end

      def self.call(env) = App.call(env)

      @@configuration = Configuration.new

      def self.configuration = @@configuration

      def self.configure(&)
        yield(@@configuration) if block_given?
        @@configuration.freeze
      end
    end
  end
end

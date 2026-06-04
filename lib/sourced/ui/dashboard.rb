# frozen_string_literal: true

# Load the gem's full setup (Sourced + Sidereal) before any dashboard
# component, so requiring 'sourced/ui/dashboard' is self-sufficient and
# does not depend on the host app requiring 'sourced' first.
require 'sourced/ui'
require 'sourced/ui/dashboard/app'

module Sourced
  module UI
    module Dashboard

      Node = Struct.new(:message, :children)

      # Builds a tree structure of messages organized by their causation relationships.
      #
      # This method takes a flat list of messages and organizes them into a hierarchical
      # tree structure where each message is a child of its causation message. Root messages
      # (those without a causation_id or whose parent is not in the set) become top-level nodes.
      #
      # @param messages [Array] An array of message objects. Each message should have an `id`
      #   attribute and an optional `causation_id` attribute indicating its parent message.
      #
      # @return [Array<Node>] An array of root {Node} objects. Each Node contains a
      #   message and an array of child nodes representing messages caused by that message.
      def self.build_causation_tree(messages)
        node_map = messages.each_with_object({}) { |msg, map| map[msg.id] = Node.new(msg, []) }

        root_nodes = []

        node_map.values.each do |node|
          if node.message.causation_id == node.message.id
            # Self-caused — this is a root message
            root_nodes << node
          else
            parent = node_map[node.message.causation_id]
            if parent
              parent.children << node
            else # causation message is not in set
              root_nodes << node
            end
          end
        end

        root_nodes
      end

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

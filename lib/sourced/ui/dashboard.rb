# frozen_string_literal: true

require 'sourced/ui/dashboard/app'

module Sourced
  module UI
    module Dashboard

      Node = Struct.new(:message, :children)

      # Builds a tree structure of events organized by their causation relationships.
      #
      # This method takes a flat list of events and organizes them into a hierarchical
      # tree structure where each event is a child of its causation event. Root events
      # (those without a parent causation event) become the top-level nodes.
      #
      # @param events [Array] An array of event objects. Each event should have an `id`
      #   attribute and a `causation_id` attribute indicating its parent event.
      #
      # @return [Array<Node>] An array of root {Node} objects. Each Node contains a
      #   message (the event) and an array of child nodes representing events caused
      #   by that event.
      #
      # @example Build a causation tree from events
      #   events = [event1, event2, event3]
      #   roots = Sourced::UI::Dashboard.build_causation_tree(events)
      #   roots.each do |root|
      #     puts "Root: #{root.message.id}"
      #     root.children.each do |child|
      #       puts "  Child: #{child.message.id}"
      #     end
      #   end
      def self.build_causation_tree(events)
        # Create a lookup hash for quick access to events by ID
        node_map = events.each_with_object({}) { |event, map| map[event.id] = Node.new(event, []) }

        # Track root events (those without parents)
        root_nodes = []

        # Build parent-child relationships
        node_map.values.each do |node|
          if node.message.causation_id == node.message.id
            # This is a root event
            root_nodes << node
          else
            # Find parent and add this event as its child
            parent = node_map[node.message.causation_id]
            if parent
              parent.children << node if parent
            else # causation event is not in set (command not appended to log?)
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

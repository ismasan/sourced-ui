# frozen_string_literal: true

module Sourced
  module UI
    # A reactor's flows as one directed graph, for Components::FlowDiagram to
    # lay out left to right: every flow the reactor takes part in, from where
    # it starts through to its end.
    #
    # A flow starts at an initiator: a command nothing in the topology
    # dispatches (a person, or something outside the app, sends it), or an
    # event nothing appends that something consumes. The graph is what's
    # reachable downstream of the initiators reaching any of the reactor's
    # steps: the events their commands append, the read models those feed and
    # the reactions to them, the commands those dispatch, and on. A loop only
    # reactions dispatch into (a retry, a timer's tick) has no initiator: a
    # step of the reactor nothing reaches is reached from a command (the
    # reactor's first) that reaches it.
    #
    # A projector's reaction consumes its read model, not the event it reacts
    # to, so it's in the graph only once that event is. The event comes from
    # the reaction's +reacts_to+, when the topology has it, or from its id
    # (+"<event type>-<group_id>-aut"+). A catch-all reaction reacts to
    # whatever its read model reads.
    #
    # Each node is drawn once, however many lead to it: several events feeding
    # one read model meet at it. Edges closing a cycle stay in the graph; the
    # diagram decides how to draw them.
    class FlowGraph
      # +own+: one of the reactor's steps, or an event it appends.
      Node = Data.define(:id, :kind, :name, :group_id, :group_label, :own, :schema, :tags, :transition)
      Edge = Data.define(:from, :to)

      MAX_NODES = 120

      # @param topology [Array<#to_h>] Sourced.topology's nodes
      # @param group_id [String] the reactor's group_id
      # @return [FlowGraph]
      def self.build(topology, group_id) = new(topology.map(&:to_h), group_id)

      attr_reader :group_id, :nodes, :edges, :starts

      def initialize(topology, group_id)
        @group_id = group_id
        @all = topology
        @by_id = topology.to_h { [it[:id], it] }
        @consumers = Hash.new { |h, k| h[k] = [] }
        topology.each { |node| Array(node[:consumes]).each { @consumers[it] << node[:id] } }
        @produced = topology.flat_map { Array(it[:produces]) }.to_set
        @truncated = false

        @starts = roots
        reached = reach(@starts)
        @nodes = @all.select { reached.include?(it[:id]) }.map { node(it, reached) }
        @edges = @nodes.flat_map do |node|
          downstream(node.id).select { reached.include?(it) }.map { Edge.new(from: node.id, to: it) }
        end
      end

      def empty? = @nodes.empty?

      # Whether the graph was cut short at MAX_NODES.
      def truncated? = @truncated

      private

      # The initiators whose flows reach the reactor, then a command for each
      # loop of the reactor's they don't.
      def roots
        initiators = @all.select do |node|
          next false if @produced.include?(node[:id])

          node[:type] == 'command' || (node[:type] == 'event' && @consumers[node[:id]].any?)
        end
        steps = @all.filter_map { it[:id] if step?(it) }.to_set
        starts = initiators.select { |start| reach([start[:id]]).intersect?(steps) }.map { it[:id] }
        uncovered = steps - reach(starts)
        mine, others = @all.select { it[:type] == 'command' }.partition { it[:group_id] == @group_id }
        (mine + others).each do |command|
          break if uncovered.empty?

          reached = reach([command[:id]])
          next unless reached.intersect?(uncovered)

          starts << command[:id]
          uncovered -= reached
        end
        starts
      end

      def step?(node) = node[:group_id] == @group_id && node[:type] != 'event'

      # The ids reachable from +starts+, a projector's reactions only once
      # what they react to is. Reached again until nothing more is: a read
      # model may be reached before the event one of its reactions reacts to.
      def reach(starts)
        reached = starts.to_set
        loop do
          added = reached.flat_map { downstream(it) }.uniq.reject { reached.include?(it) }.select { reacts?(it, reached) }
          break reached if added.empty?

          if reached.size + added.size > MAX_NODES
            @truncated = true
            break reached
          end
          reached.merge(added)
        end
      end

      def downstream(id)
        node = @by_id.fetch(id)
        (Array(node[:produces]) + @consumers[id]).select { @by_id.key?(it) }.uniq
      end

      def reacts?(id, reached)
        triggers = triggers_of(@by_id.fetch(id))
        triggers.nil? || triggers.any? { reached.include?(it) }
      end

      # The events an automation reacts to, or nil for anything not one.
      def triggers_of(node)
        return unless node[:type] == 'automation'
        return Array(node[:reacts_to]) if node[:reacts_to]

        Array(node[:consumes]).flat_map do |id|
          next [id] unless @by_id.dig(id, :type) == 'readmodel'

          event = node[:id].delete_suffix("-#{node[:group_id]}-aut")
          @by_id.dig(event, :type) == 'event' ? [event] : Array(@by_id[id][:consumes])
        end
      end

      # An event belongs to what appends it in the graph (a command, or else
      # an automation), not to the reactor the topology registered it under:
      # that's whichever reactor came first, maybe one that only reads it.
      def node(raw, reached)
        group_id = raw[:group_id]
        group_label = raw[:group_label] || group_id
        if raw[:type] == 'event'
          appending = @all.select { reached.include?(it[:id]) && Array(it[:produces]).include?(raw[:id]) }
          if (by = appending.find { it[:type] == 'command' } || appending.find { it[:type] == 'automation' })
            group_id = by[:group_id]
            group_label = by[:group_label] || group_id
          end
        end
        Node.new(id: raw[:id], kind: raw[:type].to_sym, name: raw[:name], group_id:, group_label:,
                 own: group_id == @group_id, schema: raw[:schema] || {}, tags: raw[:tags] || [],
                 transition: raw[:transition] == true)
      end
    end
  end
end

# frozen_string_literal: true

module Sourced
  module UI
    # A reactor's slice of the topology (Sourced.topology), laid out as an
    # event model: what triggers it, the commands it decides, the events they
    # append, and on downstream through whatever consumes those events (other
    # reactors' reactions, read models), to the commands those dispatch, and so on.
    #
    # The graph's edges are the topology's: a node's +produces+, and the nodes
    # that +consume+ it. The flow is walked from each event the reactor
    # consumes from elsewhere (with the commands that append it, for context)
    # and from each of its own commands and automations. It's then laid out as
    # a timeline, one node per column: each after the nodes leading to it, so
    # a read model comes after every event it reads.
    #
    # Lanes, top to bottom: automations, commands and read models, then the
    # events of each reactor that appends them, the reactor's own first.
    class EventFlow
      Node = Data.define(:id, :kind, :name, :group_id, :lane, :column, :own)
      Edge = Data.define(:from, :to)
      Lane = Data.define(:id, :kind, :label)

      AUTOMATIONS = 'automations'
      INTERACTIONS = 'interactions'

      MAX_DEPTH = 8     # steps from a chain's start
      MAX_NODES = 60
      MAX_PRODUCERS = 3 # commands shown appending a trigger event

      # @param topology [Array<#to_h>] Sourced.topology's nodes
      # @param group_id [String] the reactor's group_id
      # @return [EventFlow]
      def self.build(topology, group_id) = new(topology.map(&:to_h), group_id)

      attr_reader :group_id, :nodes, :edges, :lanes

      def initialize(topology, group_id)
        @group_id = group_id
        @by_id = topology.to_h { [it[:id], it] }
        @consumers = Hash.new { |h, k| h[k] = [] }
        @producers = Hash.new { |h, k| h[k] = [] }
        topology.each do |node|
          Array(node[:consumes]).each { @consumers[it] << node[:id] }
          Array(node[:produces]).each { @producers[it] << node[:id] }
        end

        @order = [] # the flow's node ids, in the order they're reached
        @truncated = false
        collect(topology.select { it[:group_id] == group_id && it[:type] != 'event' })
        @columns = {}
        @order.each { place(it, []) }
        @nodes = build_nodes
        @lanes = build_lanes
        @edges = build_edges
      end

      # Whether the flow goes on past what's shown.
      def truncated? = @truncated

      def empty? = @nodes.empty?

      def columns = @nodes.empty? ? 0 : @nodes.map(&:column).max + 1

      private

      def downstream(id)
        node = @by_id.fetch(id)
        (Array(node[:produces]) + @consumers[id]).select { @by_id.key?(it) }.uniq
      end

      def upstream(id)
        node = @by_id.fetch(id)
        (Array(node[:consumes]) + @producers[id]).select { @by_id.key?(it) }.uniq
      end

      def collect(own)
        own_ids = own.map { it[:id] }
        triggers = own.flat_map { Array(it[:consumes]) }.uniq.select { @by_id.dig(it, :type) == 'event' }

        triggers.each do |event|
          @producers[event].reject { own_ids.include?(it) }.first(MAX_PRODUCERS).each { add(it) }
          walk(event)
        end
        own_ids.each { walk(it) }
      end

      def add(id)
        @order << id unless @order.include?(id)
      end

      # Breadth first from +start+, as far as MAX_DEPTH steps.
      def walk(start)
        return if @order.include?(start)

        queue = [[start, 0]]
        until queue.empty?
          id, depth = queue.shift
          next if @order.include?(id)

          if @order.size >= MAX_NODES
            @truncated = true
            break
          end

          add(id)
          downstream(id).each do |next_id|
            next if @order.include?(next_id)

            if depth + 1 > MAX_DEPTH
              @truncated = true
            else
              queue << [next_id, depth + 1]
            end
          end
        end
      end

      # The next column, after the flow's nodes leading to +id+. +path+ breaks
      # cycles: a node on it is left to be placed where the walk reached it.
      def place(id, path)
        return if @columns.key?(id) || path.include?(id)

        upstream(id).each { place(it, path + [id]) if @order.include?(it) }
        @columns[id] = @columns.size unless @columns.key?(id)
      end

      def lane_of(node)
        case node[:type]
        in 'automation' then AUTOMATIONS
        in 'command' | 'readmodel' then INTERACTIONS
        in 'event' then "events:#{node[:group_id]}"
        end
      end

      def build_nodes
        @columns.sort_by(&:last).map do |id, column|
          node = @by_id.fetch(id)
          Node.new(id:, kind: node[:type].to_sym, name: node[:name], group_id: node[:group_id],
                   lane: lane_of(node), column:, own: node[:group_id] == @group_id)
        end
      end

      # The lanes with nodes in them.
      def build_lanes
        event_groups = @nodes.select { it.kind == :event }.map(&:group_id).uniq
        event_groups = event_groups.partition { it == @group_id }.flatten
        lanes = [
          Lane.new(id: AUTOMATIONS, kind: :automation, label: 'Automations'),
          Lane.new(id: INTERACTIONS, kind: :interaction, label: 'Commands · Read models'),
          *event_groups.map { Lane.new(id: "events:#{it}", kind: :event, label: it) }
        ]
        lanes.select { |lane| @nodes.any? { it.lane == lane.id } }
      end

      def build_edges
        @columns.keys.flat_map do |id|
          downstream(id).select { @columns.key?(it) }.map { Edge.new(from: id, to: it) }
        end
      end
    end
  end
end

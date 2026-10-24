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
    # a read model comes after every event it reads. Events that come straight
    # from the same nodes (alternatives a command may append) share a column,
    # stacked in their lane's rows.
    #
    # Lanes, top to bottom: automations, commands and read models, then the
    # events of each reactor that appends them, the reactor's own first.
    class EventFlow
      # +schema+ is the message's payload JSON schema, empty for other nodes.
      # +tags+ say what else it leads to that isn't drawn (see MachineSlice).
      # +transition+: a machine's state event.
      Node = Data.define(:id, :kind, :name, :group_id, :group_label, :lane, :column, :row, :own, :schema, :tags, :transition)
      Edge = Data.define(:from, :to)
      Lane = Data.define(:id, :kind, :label, :rows)

      AUTOMATIONS = 'automations'
      INTERACTIONS = 'interactions'

      MAX_DEPTH = 8     # steps from a chain's start, unless built with another
      MAX_NODES = 60
      MAX_PRODUCERS = 3 # commands shown appending a trigger event

      # @param topology [Array<#to_h>] Sourced.topology's nodes
      # @param group_id [String] the reactor's group_id
      # @param max_depth [Integer] how many steps to follow from each start
      # @param seeds [Array<String>, nil] the ids the flow is about (the reactor's own commands,
      #   automations and read models, if nil)
      # @param entry [String, nil] an event to start from, after what appends it
      # @return [EventFlow]
      def self.build(topology, group_id, max_depth: MAX_DEPTH, seeds: nil, entry: nil)
        new(topology.map(&:to_h), group_id, max_depth:, seeds:, entry:)
      end

      attr_reader :group_id, :nodes, :edges, :lanes

      def initialize(topology, group_id, max_depth: MAX_DEPTH, seeds: nil, entry: nil)
        @group_id = group_id
        @max_depth = max_depth
        @by_id = topology.to_h { [it[:id], it] }
        @consumers = Hash.new { |h, k| h[k] = [] }
        @producers = Hash.new { |h, k| h[k] = [] }
        topology.each do |node|
          Array(node[:consumes]).each { @consumers[it] << node[:id] }
          Array(node[:produces]).each { @producers[it] << node[:id] }
        end

        @order = [] # the flow's node ids, in the order they're reached
        @truncated = false
        @context = Set.new # what leads into the flow from outside it, shown but not followed
        own = seeds ? topology.select { seeds.include?(it[:id]) } : topology.select { it[:group_id] == group_id && it[:type] != 'event' }
        collect(own, entry)
        @columns = {}
        @rows = {}
        @sharing = {}               # [lane, the flow's nodes leading to an event] => its column
        @used = Hash.new(0)         # [lane, column] => rows taken
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

      # The entry first, then each event the flow's own nodes consume from
      # outside it, each after up to MAX_PRODUCERS of what appends it; then the
      # own nodes nothing has reached yet.
      def collect(own, entry)
        own_ids = own.map { it[:id] }
        triggers = own.flat_map { Array(it[:consumes]) }.uniq.select { @by_id.dig(it, :type) == 'event' }
        triggers = [entry, *triggers].uniq if entry && @by_id.key?(entry)

        triggers.each do |event|
          @producers[event].reject { own_ids.include?(it) }.first(MAX_PRODUCERS).each do |id|
            @context << id
            add(id)
          end
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

            if depth + 1 > @max_depth
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

        from = upstream(id).select { @order.include?(it) }
        from.each { place(it, path + [id]) }
        return if @columns.key?(id)

        node = @by_id.fetch(id)
        lane = lane_of(node)
        column = @sharing[[lane, from.sort]] if node[:type] == 'event' && from.any?
        column ||= @columns.empty? ? 0 : @columns.values.max + 1
        @sharing[[lane, from.sort]] ||= column if node[:type] == 'event' && from.any?
        @columns[id] = column
        @rows[id] = @used[[lane, column]]
        @used[[lane, column]] += 1
      end

      def lane_of(node)
        case node[:type]
        in 'automation' then AUTOMATIONS
        in 'command' | 'readmodel' then INTERACTIONS
        in 'event' then "events:#{node[:group_id]}"
        end
      end

      def build_nodes
        @columns.sort_by { |id, column| [column, @rows.fetch(id)] }.map do |id, column|
          node = @by_id.fetch(id)
          Node.new(id:, kind: node[:type].to_sym, name: node[:name], group_id: node[:group_id],
                   group_label: node[:group_label] || node[:group_id],
                   lane: lane_of(node), column:, row: @rows.fetch(id), own: node[:group_id] == @group_id && !@context.include?(id),
                   schema: node[:schema] || {},
                   tags: node[:tags] || [], transition: node[:transition] == true)
        end
      end

      # The lanes with nodes in them.
      def build_lanes
        event_groups = @nodes.select { it.kind == :event }.to_h { [it.group_id, it.group_label] }
        event_groups = event_groups.partition { |id, _| id == @group_id }.flatten(1)
        lanes = [
          [AUTOMATIONS, :automation, 'Automations'],
          [INTERACTIONS, :interaction, 'Commands · Read models'],
          *event_groups.map { |id, label| ["events:#{id}", :event, label] }
        ]
        lanes.filter_map do |id, kind, label|
          rows = @nodes.select { it.lane == id }.map(&:row).max
          Lane.new(id:, kind:, label:, rows: rows + 1) if rows
        end
      end

      def build_edges
        @columns.keys.flat_map do |id|
          downstream(id).select { @columns.key?(it) }.map { Edge.new(from: id, to: it) }
        end
      end
    end
  end
end

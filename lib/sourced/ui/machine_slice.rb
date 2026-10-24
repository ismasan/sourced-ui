# frozen_string_literal: true

module Sourced
  module UI
    # A machine's event model in one state: what it takes there, what that
    # appends, and what reacts downstream, as an EventFlow.
    #
    # The topology is cut down to the state before EventFlow walks it: of the
    # machine's own commands and automations, only the commands the state
    # accepts (its own and its enclosing states') and the automations of the
    # state and its enclosing states remain, so the walk can't wander into the
    # rest of the machine. Everything outside the machine stays.
    #
    # The slice starts with how the machine gets into the state: the state's
    # own event, after what appends it elsewhere in the machine (Suspend, from
    # active, before Suspended), shown but not followed.
    #
    # A command keeps the data events it appends, and only the state changes it
    # can make from this state (the chart's targets for it here), each an event
    # like any other. One that may leave the machine where it is (a data-only
    # command, or one that may not move) is tagged +stays+: staying appends no
    # state event to draw.
    module MachineSlice
      extend self

      # @param machine [Class<Sourced::Machine>]
      # @param path [String] a state's path, as Machine.to_h ids it
      # @param topology [Array<#to_h>] Sourced.topology's nodes
      # @return [EventFlow]
      def build(machine, path, topology)
        rows = MachineChart.rows(machine.to_h)
        row = rows.find { it.path == path } || raise(ArgumentError, "#{machine} has no state #{path.inspect}")
        group = machine.group_id
        around = enclosing(path)
        state_events = rows.reject { it.type == 'initial' }.to_set { state_type(machine, it.path) }
        moves = row.accepted.group_by { it[:event] }

        sliced = topology.map(&:to_h).filter_map do |node|
          next node unless node[:group_id] == group

          case node[:type]
          in 'event' then node
          in 'automation' then node if around.include?(node[:state])
          in 'command'
            next unless (transitions = moves[node[:id]])

            reached = transitions.flat_map { |t| t[:targets].map { state_type(machine, it) } }
            stays = transitions.any? { it[:targets].empty? || it[:optional] }
            node.merge(produces: node[:produces].reject { state_events.include?(it) && !reached.include?(it) },
                       tags: stays ? ['stays'] : [])
          else nil
          end
        end

        seeds = sliced.select { it[:group_id] == group && it[:type] != 'event' }.map { it[:id] }
        entry = state_type(machine, path) unless row.type == 'initial'
        if entry
          # What moves the machine in, from elsewhere: only that move drawn.
          arriving = topology.map(&:to_h).select do |node|
            node[:group_id] == group && node[:type] != 'event' && !seeds.include?(node[:id]) && Array(node[:produces]).include?(entry)
          end
          sliced += arriving.map { it.merge(produces: [entry], consumes: [], tags: []) }
        end

        EventFlow.build(sliced, group, max_depth: 5, seeds:, entry:)
      end

      private

      # +path+ and the states enclosing it: a.b.c => a, a.b, a.b.c
      def enclosing(path)
        parts = path.split('.')
        parts.each_index.map { parts[0..it].join('.') }
      end

      # The event a machine appends moving into a state. A transition to a
      # state's history moves into the state.
      def state_type(machine, path)
        machine.tree.node_at(path.sub(/\.\$(deep_)?history\z/, '')).key.type
      end
    end
  end
end

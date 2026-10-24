# frozen_string_literal: true

module MachineHelpers
  # The events +machine+ appends deciding +commands+ one after another, from
  # no history: a history to evolve an instance from.
  def decided(machine, keys, *commands)
    commands.reduce([]) do |history, command|
      instance = machine.new(keys)
      instance.evolve(history)
      raise ArgumentError, "#{machine} doesn't take #{command.class} here" unless instance.handles_command?(command)

      read = Sourced::ReadResult.new(messages: history, guard: Sourced::ConsistencyGuard.new(query: [], last_position: 0))
      history + machine.handle_batch(keys, [command], history: read, replaying: false).flat_map do |actions, _|
        Array(actions).select { Sourced::Actions::Append === it }.flat_map(&:messages)
      end
    end
  end
end

# frozen_string_literal: true

require 'set'

module Sourced
  module UI
    # A Sourced::Machine instance's history, to travel through: every message
    # in its partition, in log order, each with the states the machine is in
    # once it has evolved up to it. #at gives the instance as it was at any
    # log position.
    #
    #   timeline = MachineTimeline.load(OrderMachine, { order_id: 'o1' })
    #   timeline.steps.map(&:paths) # => [['placed'], ['placed'], ['shipped'], ...]
    #   timeline.at(12).machine.paths
    class MachineTimeline
      # A message in the partition, and the paths of the machine's active
      # states after it. +entered+: those it entered, not active before it.
      # +moved+: whether it changed them.
      Step = Data.define(:message, :paths, :entered, :moved) do
        def position = message.position
        def moved? = moved
      end

      # @param machine [Class<Sourced::Machine>]
      # @param values [Hash{Symbol => String}] a value for each of the machine's partition keys
      # @param store [Sourced::Store]
      # @return [MachineTimeline]
      def self.load(machine, values, store: Sourced.store)
        new(machine, values, store.read_partition(values, handled_types: message_types(machine)).messages)
      end

      # The types read into the timeline: those the machine handles and
      # evolves from, and those it defines (the events its handlers append
      # without moving it). Messages of any other type aren't the machine's.
      #
      # @return [Array<String>]
      def self.message_types(machine)
        own = "#{machine.message_prefix}."
        defined = Sourced::Message.registry.all.map(&:type).select { it.start_with?(own) }
        (machine.handled_messages + machine.handled_messages_for_evolve).map(&:type) | defined
      end

      attr_reader :machine, :values, :steps

      # @param messages [Array<Sourced::PositionedMessage>] the partition's, in log order
      def initialize(machine, values, messages)
        @machine = machine
        @values = values
        @evolvable = machine.handled_messages_for_evolve.to_set
        instance = machine.new(values)
        before = instance.machine.paths
        @steps = messages.map do |message|
          evolve(instance, message)
          paths = instance.machine.paths
          Step.new(message:, paths:, entered: paths - before, moved: paths != before).tap { before = paths }
        end
      end

      def messages = steps.map(&:message)
      def empty? = steps.empty?

      # The log position of its last message, 0 for none.
      def last_position = steps.last&.position || 0

      # The step at +position+: the last one at or before it. nil before the first.
      def step_at(position) = steps.reverse_each.find { it.position <= position }

      # A fresh instance, evolved from the messages up to +position+ (inclusive),
      # or from all of them for nil.
      #
      # @param position [Integer, nil]
      # @return [Sourced::Machine]
      def at(position = nil)
        instance = machine.new(values)
        steps.each do |step|
          break if position && step.position > position

          evolve(instance, step.message)
        end
        instance
      end

      private

      # As Sourced.load evolves: only the messages the machine evolves from.
      def evolve(instance, message)
        instance.evolve([message]) if @evolvable.include?(message.class)
      end
    end
  end
end

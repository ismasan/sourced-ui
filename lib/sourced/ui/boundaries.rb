# frozen_string_literal: true

module Sourced
  module UI
    # Where messages cross the boundaries between reactors: the commands one
    # reactor dispatches to another, the events one reacts to, projects or
    # evolves from that another appends, and the children a machine starts.
    # Each reactor's own lifecycle (a command and the events it decides) stays
    # inside it, and is left out.
    #
    # Built from Sourced.topology, and the reactors themselves for what it
    # doesn't say: what each evolves its state from (a child machine its
    # +Started+; a decider another reactor's events), and which reactor a
    # message class is defined in.
    #
    # A message's producers are the reactors whose commands or automations
    # declare it among what they produce, never the topology event node's
    # +group_id+: that's whichever reactor registered first that mentions it,
    # a projector as much as the decider appending it. A consumed message no
    # reactor declares producing (a handler's undeclared event) is put down to
    # the reactor it's defined in, if any, and otherwise listed as #unattributed.
    class Boundaries
      # +entries+: the ids of the commands it handles that no reactor
      # dispatches, sent from outside (a UI, an API, a script).
      Reactor = Data.define(:group_id, :label, :reactor, :entries)

      # One message crossing from one reactor to another. +to+ is nil for a
      # command dispatched to no registered reactor. +relation+ is how +to+
      # takes it: :dispatches (handles a command), :starts (a child machine
      # started by its +Started+), :reacts (an automation), :projects (a read
      # model) or :evolves (another reactor's state). +via+ names what takes it.
      Crossing = Data.define(:from, :to, :message, :name, :kind, :relation, :via)

      # Every crossing between two reactors one way, drawn as one arrow.
      # +kind+ is :command (dispatched or started), :event (reacted to) or
      # :projection (read: projected or evolved from).
      Link = Data.define(:id, :from, :to, :kind, :crossings)

      # A reactor's kind, by the class it subclasses.
      KINDS = {
        Sourced::Machine => 'machine',
        Sourced::Decider => 'decider',
        Sourced::Projector => 'projector',
        Sourced::DurableWorkflow => 'workflow'
      }.freeze

      LINK_KINDS = { dispatches: :command, starts: :command, reacts: :event, projects: :projection, evolves: :projection }.freeze

      # @param topology [Array<#to_h>] Sourced.topology's nodes
      # @param reactors [Array<Class>] the registered reactors
      # @return [Boundaries]
      def self.build(topology, reactors = []) = new(topology.map(&:to_h), reactors)

      attr_reader :reactors, :crossings, :links, :unattributed

      def initialize(topology, reactors)
        @reactor_classes = reactors
        @messages = topology.select { it[:type] in 'command' | 'event' }.to_h { [it[:id], it] }
        @reactors = build_reactors(topology, reactors)
        producers = producers_of(topology)
        consumers = consumers_of(topology)

        @unattributed = []
        @crossings = consumers.flat_map do |id, takers|
          from = producers[id]
          # Sent from outside: Reactor#entries.
          next [] if from.empty? && kind_of(id) == :command
          if from.empty?
            home = home_of(id)
            next takers.each { @unattributed << [id, name_of(id), it] }.then { [] } unless home

            from = [home]
          end
          from.flat_map do |producer|
            takers.reject { it[0] == producer }.map do |(group, relation, via)|
              Crossing.new(from: producer, to: group, message: id, name: name_of(id), kind: kind_of(id), relation:, via:)
            end
          end
        end
        # Dispatched, and handled by none of them.
        producers.each do |id, from|
          next if consumers.key?(id) || @messages[id]&.dig(:type) == 'event'

          from.each { @crossings << Crossing.new(from: it, to: nil, message: id, name: name_of(id), kind: :command, relation: :dispatches, via: nil) }
        end
        @crossings = dedupe(@crossings)

        index = 0
        @links = @crossings.select(&:to).group_by { [it.from, it.to, LINK_KINDS.fetch(it.relation)] }.map do |(from, to, kind), list|
          Link.new(id: "link-#{index += 1}", from:, to:, kind:, crossings: list)
        end
      end

      def empty? = @crossings.empty?

      # The same boundaries a level up: reactors sharing the first segment of
      # their group_id in one Group, as the dashboard's consumer group list
      # groups them. See Grouped.
      def grouped = @grouped ||= Grouped.new(self)

      # The reactors no message crosses into or out of.
      def isolated
        linked = @crossings.flat_map { [it.from, it.to] }.compact.to_set
        @reactors.reject { linked.include?(it.group_id) }
      end

      def reactor(group_id) = @reactors.find { it.group_id == group_id }

      private

      def build_reactors(topology, reactors)
        handled = topology.select { it[:type] == 'command' }.group_by { it[:group_id] }
        dispatched = topology.select { it[:type] == 'automation' }.flat_map { it[:produces] }.to_set
        # A child machine's Stop is its parent's to send, by the runtime.
        stops = reactors.filter_map { it::Stop.type if Class === it && it < Sourced::Machine && it.const_defined?(:Stop, false) }.to_set
        entries = ->(group_id) { (handled[group_id] || []).map { it[:id] }.reject { dispatched.include?(it) || stops.include?(it) } }

        known = reactors.map do |r|
          Reactor.new(group_id: r.group_id, label: r.group_label, reactor: r, entries: entries.(r.group_id))
        end
        # Groups only the topology knows (hand-built topologies).
        seen = known.map(&:group_id).to_set
        rest = topology.reject { seen.include?(it[:group_id]) }.uniq { it[:group_id] }.map do |node|
          Reactor.new(group_id: node[:group_id], label: node[:group_label] || node[:group_id], reactor: nil,
                      entries: entries.(node[:group_id]))
        end
        known + rest
      end

      # Message id => the groups declaring they produce it, in topology order.
      def producers_of(topology)
        producers = Hash.new { |h, k| h[k] = [] }
        topology.each do |node|
          next unless node[:type] in 'command' | 'automation'

          Array(node[:produces]).each { producers[it] |= [node[:group_id]] }
        end
        producers
      end

      # Message id => [group, relation, via] for each consumer.
      def consumers_of(topology)
        consumers = Hash.new { |h, k| h[k] = [] }
        add = ->(id, taker) { consumers[id] << taker unless consumers[id].include?(taker) }
        topology.each do |node|
          case node[:type]
          in 'command' then add.(node[:id], [node[:group_id], :dispatches, node[:name]])
          in 'automation'
            Array(node[:consumes]).each { add.(it, [node[:group_id], :reacts, node[:name]]) if @messages[it] }
          in 'readmodel'
            Array(node[:consumes]).each { add.(it, [node[:group_id], :projects, node[:group_label] || node[:name]]) if @messages[it] }
          else nil
          end
        end
        # What each reactor evolves its state from, besides what its read
        # model projects: another's events a decider builds its decisions on,
        # and a child machine's own Started, appended by its parent.
        @reactor_classes.each do |reactor|
          next if !(Class === reactor) || reactor < Sourced::Projector

          evolved_types(reactor).each do |klass|
            next if klass < Sourced::Command

            started = reactor.const_defined?(:Started, false) && reactor::Started == klass
            next if consumers[klass.type].any? { it[0] == reactor.group_id }

            add.(klass.type, [reactor.group_id, started ? :starts : :evolves, reactor.name])
          end
        end
        consumers
      end

      def evolved_types(reactor)
        selector = reactor.respond_to?(:evolve_selector) ? reactor.evolve_selector : reactor.history_selector
        selector.types
      rescue StandardError
        []
      end

      # The group of the registered reactor the message's class is defined
      # in (SpecShop::Parcel::Delivered: SpecShop::Parcel), the innermost.
      def home_of(id)
        name = name_of(id)
        @reactor_classes.select { name.start_with?("#{it.name}::") }.max_by { it.name.length }&.group_id
      end

      def name_of(id) = @messages.dig(id, :name) || Sourced::Message.registry[id]&.name || id

      def kind_of(id)
        type = @messages.dig(id, :type)
        return type.to_sym if type

        klass = Sourced::Message.registry[id]
        klass && klass < Sourced::Command ? :command : :event
      end

      # One crossing for each message between two reactors and how it's
      # taken, the names of what takes it together.
      def dedupe(crossings)
        crossings.group_by { [it.from, it.to, it.message, it.relation] }.map do |_, list|
          list.first.with(via: list.map(&:via).compact.uniq.join(', ').then { it.empty? ? nil : it })
        end
      end
      # Reactors whose group_ids share a first segment (+expenses+ in
      # +expenses.categorizer+), as one. Its +group_id+ is the segment and
      # +.*+, apart from any reactor's. +inside+ counts the crossings between
      # its members, which Grouped leaves out.
      Group = Data.define(:group_id, :label, :members, :entries, :inside) do
        def reactor = nil
      end

      # Boundaries with each namespace's reactors as one Group: only messages
      # crossing from one namespace to another cross a boundary, and are
      # linked. A reactor whose group_id has one segment stands alone, as on
      # the consumer group list. Answers what BoundaryMap draws.
      class Grouped
        attr_reader :reactors, :crossings, :links

        # @param boundaries [Boundaries]
        def initialize(boundaries)
          @boundaries = boundaries
          crossings = boundaries.crossings.map { it.with(from: key(it.from), to: it.to && key(it.to)) }
          inner, @crossings = crossings.partition { it.from == it.to }
          @crossings = @crossings.group_by { [it.from, it.to, it.message, it.relation] }.map do |_, list|
            list.first.with(via: list.map(&:via).compact.uniq.join(', ').then { it.empty? ? nil : it })
          end
          inside = inner.map(&:from).tally
          @reactors = boundaries.reactors.group_by { key(it.group_id) }.map do |key, members|
            next members.first if key == members.first.group_id

            Group.new(group_id: key, label: label(key, members), members:, entries: members.flat_map(&:entries),
                      inside: inside.fetch(key, 0))
          end
          index = 0
          @links = @crossings.select(&:to).group_by { [it.from, it.to, LINK_KINDS.fetch(it.relation)] }.map do |(from, to, kind), list|
            Link.new(id: "ns-link-#{index += 1}", from:, to:, kind:, crossings: list)
          end
        end

        def empty? = @crossings.empty?

        def reactor(group_id) = @reactors.find { it.group_id == group_id }

        private

        def key(group_id)
          head, rest = group_id.split('.', 2)
          rest ? "#{head}.*" : group_id
        end

        # The module its members' classes share (+Expenses+), as the consumer
        # group list titles a namespace; else the segment.
        def label(key, members)
          heads = members.map { (it.reactor&.name || it.label).to_s.split('::').first }.uniq
          heads.size == 1 && !heads.first.to_s.empty? ? heads.first : key.delete_suffix('.*')
        end
      end
    end
  end
end

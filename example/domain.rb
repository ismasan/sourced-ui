# frozen_string_literal: true

require 'bundler/setup'
require 'sourced'
require 'sequel'

module TaskApp
  # --- Messages ---

  class Event < Sourced::Message; end
  class Command < Sourced::Message; end

  CreateTask    = Command.define('tasks.create')   { attribute :task_id, String; attribute :title, String }
  TaskCreated   = Event.define('tasks.created')     { attribute :task_id, String; attribute :title, String }
  CompleteTask  = Command.define('tasks.complete')  { attribute :task_id, String }
  TaskCompleted = Event.define('tasks.completed')   { attribute :task_id, String }

  # --- Decider ---

  # Enforces task lifecycle: can't create twice, can't complete if not created.
  class TaskDecider < Sourced::Decider
    partition_by :task_id

    state do |_partition_values|
      { created: false, completed: false }
    end

    evolve TaskCreated do |state, _event|
      state[:created] = true
    end

    evolve TaskCompleted do |state, _event|
      state[:completed] = true
    end

    command CreateTask do |state, cmd|
      raise "Task '#{cmd.payload.task_id}' already exists" if state[:created]

      event TaskCreated, task_id: cmd.payload.task_id, title: cmd.payload.title
    end

    command CompleteTask do |state, cmd|
      raise "Task '#{cmd.payload.task_id}' does not exist" unless state[:created]
      raise "Task '#{cmd.payload.task_id}' is already completed" if state[:completed]

      event TaskCompleted, task_id: cmd.payload.task_id
    end
  end

  # --- Projector ---

  # Evolves state from task events.
  # Registered as a consumer group so the dashboard has topology data.
  class TaskLogProjector < Sourced::Projector::EventSourced
    partition_by :task_id

    state do |_partition_values|
      { task_id: nil, title: nil, completed: false }
    end

    evolve TaskCreated do |state, event|
      state[:task_id] = event.payload.task_id
      state[:title] = event.payload.title
    end

    evolve TaskCompleted do |state, _event|
      state[:completed] = true
    end

    sync do |state:, messages:, **|
      # No-op — just enough to register as a consumer group
    end
  end

  # --- Configuration ---

  DB_PATH = File.join(__dir__, 'storage', 'app.db')

  Sourced.configure do |c|
    c.store = Sequel.sqlite(DB_PATH)
  end

  Sourced.register(TaskDecider)
  Sourced.register(TaskLogProjector)
end

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

    context do
      { created: false, completed: false }
    end

    evolve TaskCreated do |context, _event|
      context[:created] = true
    end

    evolve TaskCompleted do |context, _event|
      context[:completed] = true
    end

    command CreateTask => TaskCreated do |context, cmd|
      raise "Task '#{cmd.payload.task_id}' already exists" if context[:created]

      event TaskCreated, task_id: cmd.payload.task_id, title: cmd.payload.title
    end

    command CompleteTask => TaskCompleted do |context, cmd|
      raise "Task '#{cmd.payload.task_id}' does not exist" unless context[:created]
      raise "Task '#{cmd.payload.task_id}' is already completed" if context[:completed]

      event TaskCompleted, task_id: cmd.payload.task_id
    end
  end

  # --- Projector ---

  # Evolves state from task events.
  # Registered as a consumer group so the dashboard has topology data.
  class TaskLogProjector < Sourced::Projector::EventSourced
    partition_by :task_id

    context do
      { task_id: nil, title: nil, completed: false }
    end

    evolve TaskCreated do |context, event|
      context[:task_id] = event.payload.task_id
      context[:title] = event.payload.title
    end

    evolve TaskCompleted do |context, _event|
      context[:completed] = true
    end

    sync do |context:, messages:, **|
      # No-op — just enough to register as a consumer group
    end
  end

  # --- Machine ---

  # A task's review: the code and the docs are approved in parallel, and the
  # review is approved once both are. The reviewer is notified on entering
  # review, and reminded if it's still in review a minute later.
  #
  #   initial ─RequestReview─▶ in_review ║ code: initial ─ApproveCode─▶ code_approved (final)
  #                                      ║ docs: initial ─ApproveDocs─▶ docs_approved (final)
  #            in_review ─done─▶ approved (final)
  #            in_review ─RequestChanges─▶ changes_requested ─RequestReview─▶ in_review
  #            in_review, changes_requested ─Abandon─▶ abandoned (final)
  class TaskReview < Sourced::Machine
    partition_by :task_id

    context do
      { reviewer: nil, comments: [] }
    end

    InReview = State(:in_review)
    CodeApproved = State(:code_approved)
    DocsApproved = State(:docs_approved)
    ChangesRequested = State(:changes_requested)
    Approved = State(:approved)
    Abandoned = State(:abandoned)

    RequestReview = Command(:request_review) { attribute :reviewer, String }
    ApproveCode = Command(:approve_code)
    ApproveDocs = Command(:approve_docs)
    Comment = Command(:comment) { attribute :text, String }
    RequestChanges = Command(:request_changes) { attribute :reason, String }
    Abandon = Command(:abandon)
    NotifyReviewer = Command(:notify_reviewer)
    Remind = Command(:remind)

    ReviewerAssigned = Event(:reviewer_assigned) { attribute :reviewer, String }
    Commented = Event(:commented) { attribute :text, String }
    ReviewerNotified = Event(:reviewer_notified)
    Reminded = Event(:reminded)

    evolve(ReviewerAssigned) { |review, evt| review[:reviewer] = evt.payload.reviewer }
    evolve(Commented) { |review, evt| review[:comments] << evt.payload.text }

    initial do
      command RequestReview => InReview do |_review, cmd|
        event ReviewerAssigned, reviewer: cmd.payload.reviewer
        to InReview
      end
    end

    state InReview do
      entry NotifyReviewer
      after('1m' => Remind)

      command(NotifyReviewer) { |_review, _cmd| event ReviewerNotified }
      command(Remind) { |_review, _cmd| event Reminded }
      command Comment do |_review, cmd|
        event Commented, text: cmd.payload.text
      end
      command RequestChanges => ChangesRequested
      command Abandon => Abandoned

      region :code do
        initial { command ApproveCode => CodeApproved }
        final CodeApproved
      end

      region :docs do
        initial { command ApproveDocs => DocsApproved }
        final DocsApproved
      end

      done Approved
    end

    state ChangesRequested do
      command RequestReview => InReview do |_review, cmd|
        event ReviewerAssigned, reviewer: cmd.payload.reviewer
        to InReview
      end
      command Abandon => Abandoned
    end

    final Approved
    final Abandoned
  end

  # --- Configuration ---

  # A fresh file (override with DB_PATH): Sourced installs its tables on start,
  # but doesn't migrate a database created by an older Sourced.
  DB_PATH = ENV.fetch('DB_PATH') { File.join(__dir__, 'storage', 'tasks.db') }

  Sourced.config.component!('db') do
    build { Sequel.sqlite(DB_PATH) }
    teardown(&:disconnect)
  end
  Sourced.config.config!('store.install_tables') { true }

  Sourced.register(TaskDecider)
  Sourced.register(TaskLogProjector)
  Sourced.register(TaskReview)
end

# frozen_string_literal: true

# Seed script: creates tasks and completes some of them.
# Usage: cd example && bundle exec ruby seed.rb
#
# Each Sourced.handle! call appends a command and its correlated events
# so the dashboard event log shows realistic causation chains.

require_relative 'domain'
require 'securerandom'

# No workers while seeding tasks: they'd contend with its writes for the
# database. TaskDecider and TaskLogProjector run no reactions, so they can
# catch up later. The reviews start them (see settle below).
Sourced.config.defer('dispatcher')
Sourced.start!

TASK_COUNT = (ENV['TASK_COUNT'] || 1000).to_i

ADJECTIVES = %w[urgent important optional deferred critical blocked pending reviewed approved draft].freeze
NOUNS = %w[
  landing-page CI-pipeline API-docs auth-middleware search-indexing
  database-migration email-notifications rate-limiter caching-layer
  user-dashboard payment-integration test-suite logging-setup
  deploy-script monitoring-alerts backup-strategy data-export
  onboarding-flow error-handling access-control webhook-handler
].freeze

def random_title(index)
  "#{ADJECTIVES.sample} #{NOUNS.sample} ##{index}"
end

puts "Seeding #{TASK_COUNT} tasks..."

task_ids = TASK_COUNT.times.map do |i|
  task_id = SecureRandom.uuid

  cmd = TaskApp::CreateTask.new(
    payload: { task_id: task_id, title: random_title(i + 1) }
  )
  _cmd, _decider, events = Sourced.handle!(TaskApp::TaskDecider, cmd)

  print "\r  Created #{i + 1}/#{TASK_COUNT}"
  task_id
end
puts

# Complete ~60% of tasks
complete_count = (TASK_COUNT * 0.6).to_i
to_complete = task_ids.sample(complete_count)

to_complete.each_with_index do |task_id, i|
  cmd = TaskApp::CompleteTask.new(
    payload: { task_id: task_id }
  )
  _cmd, _decider, events = Sourced.handle!(TaskApp::TaskDecider, cmd)

  print "\r  Completed #{i + 1}/#{complete_count}"
end
puts

total_messages = TASK_COUNT + complete_count
puts "Done. #{TASK_COUNT} tasks created, #{complete_count} completed. ~#{total_messages * 2} messages (commands + events)."

# Review ~half the tasks, leaving each at a different point in TaskReview.
review = TaskApp::TaskReview

# Wait for the workers to take what a review's command appended, and what that
# sets off (its entry action's NotifyReviewer), before the next command.
# Sourced.handle! moves the machine past its command only, but the next one
# would move it past what this one appended: the workers would take those as
# replays later, and replays run no entry actions or timers.
def settle(machine, task_id, timeout: 30)
  key = "task_id:#{task_id}"
  handled = Sourced::Selector[*machine.handled_messages].by(:task_id).bind(task_id:)
  deadline = Time.now + timeout
  while Time.now < deadline
    head = Sourced.store.read(handled).messages.last.position
    offset = Sourced.store.read_offsets(group_id: machine.group_id, limit: 10_000).offsets.find { it[:partition_key] == key }
    return if offset && !offset[:claimed] && offset[:last_position] >= head

    sleep 0.01
  end
  warn "\n  #{machine} still busy with #{task_id} after #{timeout}s"
end

REVIEWERS = %w[ana bea carl dee].freeze
STEPS = {
  in_review: [],
  code_approved: [[review::ApproveCode]],
  commented: [[review::Comment, { text: 'Looks good, one nit' }], [review::ApproveDocs]],
  approved: [[review::ApproveCode], [review::ApproveDocs]],
  changes_requested: [[review::Comment, { text: 'Needs tests' }], [review::RequestChanges, { reason: 'No tests' }]],
  rereviewed: [[review::RequestChanges, { reason: 'Typo' }], [review::RequestReview, { reviewer: 'bea' }], [review::ApproveCode]],
  abandoned: [[review::Abandon]]
}.freeze

# Workers now, to run TaskReview's entry actions as the reviews go. They first
# catch up with the tasks, and would contend with the reviews for the database
# meanwhile: wait until they're idle (nothing claimed, no offset moving).
Sourced.config.start_component!('dispatcher', Thread.current)
print '  Catching up...'
offsets = -> { Sourced.store.read_offsets(limit: 100_000).offsets.map { [it[:last_position], it[:claimed]] } }
last = nil
until (now = offsets.call) == last && now.none?(&:last)
  last = now
  sleep 0.5
end
puts ' done.'

reviewed = task_ids.sample(TASK_COUNT / 2)
examples = {}
reviewed.each_with_index do |task_id, i|
  outcome, steps = STEPS.to_a[i % STEPS.size]
  [[review::RequestReview, { reviewer: REVIEWERS.sample }], *steps].each do |command_class, payload|
    Sourced.handle!(review, command_class.new(payload: { task_id:, **(payload || {}) }))
    settle(review, task_id)
  end
  examples[outcome] ||= task_id
  print "\r  Reviewed #{i + 1}/#{reviewed.size}"
end
puts

puts 'Browse a review, ex.:'
examples.each { |outcome, task_id| puts "  #{outcome}: http://localhost:9292/reactors/#{review.group_id}/instance?task_id=#{task_id}" }

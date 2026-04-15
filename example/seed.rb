# frozen_string_literal: true

# Seed script: creates tasks and completes some of them.
# Usage: cd example && bundle exec ruby seed.rb
#
# Each Sourced.handle! call appends a command and its correlated events
# so the dashboard event log shows realistic causation chains.

require_relative 'domain'
require 'securerandom'

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

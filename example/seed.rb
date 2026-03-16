# frozen_string_literal: true

# Seed script: creates tasks and completes some of them.
# Usage: cd example && bundle exec ruby seed.rb
#
# Each CCC.handle! call appends a command and its correlated events
# so the dashboard event log shows realistic causation chains.

require_relative 'domain'
require 'securerandom'

TASKS = [
  { title: 'Design landing page' },
  { title: 'Set up CI pipeline' },
  { title: 'Write API documentation' },
  { title: 'Implement auth middleware' },
  { title: 'Add search indexing' },
]

puts "Seeding #{TASKS.size} tasks..."

task_ids = TASKS.map do |attrs|
  task_id = SecureRandom.uuid

  cmd = TaskApp::CreateTask.new(
    payload: { task_id: task_id, title: attrs[:title] }
  )
  _cmd, _decider, events = CCC.handle!(TaskApp::TaskDecider, cmd)

  puts "  Created: #{attrs[:title]} (#{task_id}) -> #{events.map(&:type).join(', ')}"
  task_id
end

# Complete the first 3 tasks
task_ids.first(3).each do |task_id|
  cmd = TaskApp::CompleteTask.new(
    payload: { task_id: task_id }
  )
  _cmd, _decider, events = CCC.handle!(TaskApp::TaskDecider, cmd)

  puts "  Completed: #{task_id} -> #{events.map(&:type).join(', ')}"
end

puts "Done. #{TASKS.size} tasks created, 3 completed."

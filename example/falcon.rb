#!/usr/bin/env falcon-host
# frozen_string_literal: true

require_relative 'domain'
require 'sourced/falcon'

# Sourced.setup! reconnects SQLite after fork, so the inherited
# parent connection is never used. Suppress the warning.
SQLite3::ForkSafety.suppress_warnings!

service "task-app" do
  include Sourced::Falcon::Environment
  include Falcon::Environment::Rackup

  count 1
end

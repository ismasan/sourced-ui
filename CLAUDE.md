# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`sourced-ui` is a Ruby gem providing reactive web UI components and a monitoring dashboard for the [Sourced](https://github.com/ismasan/sourced) event sourcing framework. It combines Phlex (component-based HTML rendering) with Datastar (reactive SSE/AJAX updates) on top of Rack.

## Commands

```bash
# Install dependencies
bin/setup

# Run all tests
bundle exec rspec

# Run a single test file
bundle exec rspec spec/sourced/ui/dashboard_spec.rb

# Run a specific example by name
bundle exec rspec spec/sourced/ui/dashboard_spec.rb -e "builds tree with common root"

# Interactive console with gem loaded
bin/console

# Install gem locally
bundle exec rake install
```

## Architecture

### Module Structure

- **`Sourced::UI`** — Top-level module. Provides `streaming_command_errors` helper for processing commands in web controllers with SSE error streaming, and `configure_from` to sync Datastar executor with Sourced config.
- **`Sourced::UI::Components`** — General-purpose Phlex components (`Command` for forms with validation error streaming). Uses `Phlex::Kit` for component registration.
- **`Sourced::UI::Components::DatastarHelpers`** — DSL module providing `_d` builder for composing Datastar directives (event bindings, AJAX actions, signals) as HTML attributes.
- **`Sourced::UI::Dashboard`** — Rack-based monitoring dashboard app showing event streams, consumer groups, and causation trees.

### Key Patterns

- **Components** inherit from `Phlex::HTML` and implement `view_template`. Dashboard components access request context via `context.fetch(:view_context)`.
- **Datastar builder** (`_d`) is an immutable builder — each method returns a new copy. Chain calls like `_d.click.post('/path', retries: 3).signals(foo: 'bar').to_h` to produce HTML attribute hashes.
- **Dashboard Router** (`Dashboard::Router`) is a Rack app using pattern matching on `request.path_info`. SSE streaming routes use `datastar.stream { |sse| ... }` with `patch_elements` to push Phlex component fragments.
- **Causation trees** — `Dashboard.build_causation_tree(events)` converts flat event lists into `Node` trees based on `causation_id` relationships.

### Dependencies

- **sourced** — Event sourcing framework (local path dependency in Gemfile)
- **phlex** (~v2.3) — Component-based HTML rendering
- **datastar** (1.0.1) — Reactive HTML framework for SSE streaming and AJAX
- **rack** — HTTP server interface

### Environment Variables

- `SOURCED_UI_TESTING` — When set, disables asset caching (sets `cache-control: no-cache`)

## Conventions

- All files use `# frozen_string_literal: true`
- Ruby >= 3.1 required (uses pattern matching, Data.define, endless methods)
- Event objects have `id`, `causation_id`, `correlation_id`, `seq` attributes (from `Sourced::Message`)
- Commands use `Sourced::Command` with `valid?` and `errors[:payload]` for validation

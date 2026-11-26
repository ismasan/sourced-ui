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

- **`Sourced::UI`** — Top-level module. Loads `sidereal` and defines the gem's namespace + `Error` class.
- **`Sourced::UI::Components::MessageFilter`** — Sourced-specific Phlex component for building event/command filters. Inherits from `Sidereal::Components::BaseComponent`.
- **`Sourced::UI::Dashboard`** — Rack-based monitoring dashboard app showing event streams, consumer groups, and causation trees. Built on `Sidereal::App`.
- **`Sourced::UI::Dashboard::{Resume,Stop,Reset}ConsumerGroup`** — Typed `Sidereal::Message`s exposed via `POST /commands` for consumer-group operations.

### Key Patterns

- **Components** inherit from `Sidereal::Components::BaseComponent` (Phlex::HTML subclass with `_d` Datastar builder and `command` helper already mixed in). Dashboard components call `helpers.url('/path')` — `helpers` returns the current request's `context` (the Sidereal::Router instance with `RequestHelpers#url`).
- **Layout** (`Sourced::UI::Dashboard::Components::Layout`) inherits from `Sidereal::Components::Layout`, which auto-injects the Datastar `<script>` tag in `head` and builds the `data-signals` body attribute from a page object. Since the dashboard has no per-page object, Layout passes `NULL_PAGE` (a `Sidereal::Page` subclass instance with `page_signals: { modal: false }` and `channel_names: []`) to `super`, and overrides `updates_url` to `nil`: the dashboard's SSE routes stream their own updates, and this keeps it rendering when Sidereal itself isn't booted (`Page.stream_token` reads `Sidereal.signer`).
- **Specs** boot Sourced per example inside `Sync { }` (see `router_spec.rb`): `Sourced.start!` spawns its pollers into the current Async task, even with `workers.count` 0, and raises `Sourced::Spawner::NoTaskError` outside one.
- **Datastar builder** (`_d`, from `Sidereal::DatastarHelpers`) is an immutable builder — each method returns a new copy. Chain calls like `_d.click.post('/path', retries: 3).signals(foo: 'bar').to_h` to produce HTML attribute hashes.
- **Dashboard Service** (`Sourced::UI::Dashboard::Service < Sidereal::App`) is the routed Rack app. `GET` pages render via `component(cmp)`; SSE routes use `datastar.stream { |sse| ... }` with `patch_elements`. `POST /commands` is auto-wired by Sidereal::App — `handle MessageClass do |cmd| ... end` registers the handler.
- **Topology page** — `Sourced::UI::Boundaries.build(Sourced.topology, reactors)` derives the messages crossing between reactors (commands dispatched, events reacted to/projected/evolved from, child machines started); `Components::BoundaryMap` draws them with `LayeredLayout`. Producers come from command/automation `produces`, never the topology event node's `group_id` (first-registered wins there).
- **Component assets** — a component's own scripts are declared on it with Sidereal's assets system (`javascript 'topology/boundary_map.js', path: 'boundary_map.js'`, the file beside the component) and installed in `Dashboard::Service` with `component BoundaryMaps`; Sidereal's Layout `head` then links each at a digested `/_assets/...` URL on every page, so a script must act only on its own markup. The dashboard's stylesheet is still served by `Rack::Static` from `assets/`.
- **Causation trees** — `Dashboard.build_causation_tree(events)` converts flat event lists into `Node` trees based on `causation_id` relationships.

### Dependencies

- **sidereal** — Rack router + reactive UI framework (local path dependency in Gemfile; owns the router, Command component, DatastarHelpers, and Page primitives)
- **sourced** — Event sourcing framework (local path dependency in Gemfile)
- **phlex** (~v2.3) — Component-based HTML rendering
- **datastar** — Reactive HTML framework for SSE streaming and AJAX

### Environment Variables

- `SOURCED_UI_TESTING` — When set, disables asset caching (sets `cache-control: no-cache`)

## Conventions

- All files use `# frozen_string_literal: true`
- Ruby >= 4.0.1 required (uses pattern matching, Data.define, endless methods)
- Event objects have `id`, `causation_id`, `correlation_id`, `seq` attributes (from `Sourced::Message`)
- Commands use `Sourced::Command` with `valid?` and `errors[:payload]` for validation

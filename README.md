# Sourced::UI

Web UI for [Sourced](https://github.com/ismasan/sourced) event-sourced apps. It gives you two things:

- **A monitoring dashboard**, as a Rack app you mount in your own app. It shows the event store's e and recent messages, the causation tree of each message, your registered reactors and how they connect, and their consumer groups with their offsets and errors. You can start, stop and reset consumer groups from it, and it draws each machine's statechart and event model.
- **Components** for your own pages, such as `Statechart`, which draws a `Sourced::Machine` as an SVG statechart. They're [Phlex](https://www.phlex.fun) components built on [Sidereal](https://github.com/ismasan/sidereal)'s, which use [Datastar](https://data-star.dev) for live updates.

## Installation

Add the gem to your Gemfile. It isn't on RubyGems yet, so install it, Sourced and Sidereal from GitHub:

```ruby
gem 'sourced', github: 'ismasan/sourced'
gem 'sidereal', github: 'ismasan/sidereal'
gem 'sourced-ui', github: 'ismasan/sourced-ui'
```

## Setup

### Mounting the dashboard in a Rack app

`Sourced::UI::Dashboard` is a Rack app. It reads from `Sourced.store` and lists the reactors registered with Sourced, so configure and start Sourced first, then mount the dashboard under a path in `config.ru`:

```ruby
# config.ru
require 'sequel'
require 'sourced'
require 'sourced/ui/dashboard'

Sourced.config.component!('db') do
  build { Sequel.sqlite('db/events.db') }
  teardown(&:disconnect)
end
Sourced.register(MyDecider)
Sourced.register(MyProjector)
Sourced.start!

map '/sourced' do
  run Sourced::UI::Dashboard
end

map '/' do
  run MyApp
end
```

Sourced expects its tables to exist: create them with a migration, or set `Sourced.config.config!('store.install_tables') { true }` in development. See Sourced's README for that, and for running its workers inside your web server or in a separate process.

The dashboard builds its links and asset URLs from the path it's mounted under, so any path works. It serves its own stylesheet.

The dashboard's commands can stop and reset consumer groups, so protect it in production. It supports HTTP Basic Auth out of the box:

```ruby
Sourced::UI::Dashboard.configure do |config|
  config.basic_auth ENV.fetch('DASHBOARD_USER'), ENV.fetch('DASHBOARD_PASSWORD')
  # optional: config.basic_auth user, password, realm: 'Ops'
end
```

For anything else, mount it behind your app's authentication (for example, a Rack middleware inside the `map` block).

It keeps a session cookie, signed with `ENV['SOURCED_DASHBOARD_SESSION_SECRET']`. Set that variable to a random string of at least 64 characters in production; the built-in default is only fit for development.

### Mounting it next to a Sidereal app

With Sidereal's Sourced integration (`Sidereal.config.use Sidereal::Integrations::Sourced`), Sidereal mounts Sourced's configuration, so `Sourced.store` is your app's store and the dashboard shows your app's messages and reactors. A Sidereal app is a Rack app too, so mount both from `config.ru`:

```ruby
# config.ru
require_relative 'boot'           # loads your app and applies the Sourced integration
require 'sourced/ui/dashboard'

map '/sourced' do
  run Sourced::UI::Dashboard
end

map '/' do
  run MyApp                       # your Sidereal::App
end
```

### Header links

To add links to the dashboard's header (back to your app, for example), configure them once at boot:

```ruby
Sourced::UI::Dashboard.configure do |config|
  config.header_links([
    { label: 'Back to app', href: '/', url: false },  # url: false leaves href as is
    { label: 'Reactors', href: '/topology' }          # by default, href is relative to the dashboard's mount path
  ])
end
```

`configure` freezes the configuration, so call it only once.

### Using the components in your own pages

Require the components and render them from any Phlex view, including a Sidereal app's pages and components:

```ruby
require 'sourced/ui/components'

class OrderStatus < Sidereal::Components::BaseComponent
  def initialize(order) = @order = order  # a Sourced::Machine instance

  def view_template
    render Sourced::UI::Components::Statechart.new(@order, title: 'Order status')
  end
end
```

The components' CSS ships with the dashboard's stylesheet (see [Legend and styles](#legend-and-styles)).

## Usage

### Statechart

`Sourced::UI::Components::Statechart` draws a `Sourced::Machine` as an SVG statechart. It's a Phlex component, so you can render it from any Phlex view or call it directly.

```ruby
require 'sourced/ui/components'

class Trip < Sourced::Machine
  partition_by trip_id: String

  Planning = State(:planning)
  Booked = State(:booked)
  Cancelled = State(:cancelled)

  Start = Command(:start)
  Book = Command(:book)
  Cancel = Command(:cancel)

  initial do
    command Start => Planning
  end

  state Planning do
    command Book => Booked
    command Cancel => Cancelled
  end

  final Booked
  final Cancelled
end

# Inside a Phlex view
render Sourced::UI::Components::Statechart.new(Trip)

# Or on its own, as an SVG string
svg = Sourced::UI::Components::Statechart.new(Trip).call
```

The component takes a machine class, an instance, or anything else that responds to `#to_h` with a machine's definition (such as the Hash `Machine.to_h` returns). It calls `#to_h` on it and lays out whatever the machine defines: atomic, final and initial states, parallel states with their regions side by side, compound states (`Sourced::Machine::Part`) with their sub-states nested inside, history targets, timers (`after('15m' => Expire)`), and `done` / `on_final` transitions.

#### An instance's status

Pass an instance instead of the class to see where that machine is. Its active states are lit, states visited since their region was entered are marked, inactive regions are dimmed, and the commands it accepts right now are highlighted.

```ruby
trip = Trip.new(trip_id: 't1')
# ... evolve it from its history
render Sourced::UI::Components::Statechart.new(trip)
```

To highlight a state from the definition alone, without an instance (for example, the state a user clicked on), use `Sourced::UI::MachineChart.highlight`. It marks the state at that dotted path, and the states enclosing it, as active:

```ruby
chart = Sourced::UI::MachineChart.highlight(Trip.to_h, 'planning')
render Sourced::UI::Components::Statechart.new(chart)
```

#### Options

```ruby
Sourced::UI::Components::Statechart.new(
  Trip,
  # Accessible name for the SVG (its aria-label and <title>).
  # Defaults to "<machine name> statechart".
  title: 'Trip lifecycle',
  # Turns child machines into links: a transition that starts other machines
  # names them, and a machine is linked when this returns a URL for its group_id.
  # Return nil to leave one unlinked. Without href, none are linked.
  href: ->(group_id) { "/reactors/#{group_id}" }
)
```

#### Element ids and classes

Each state is rendered as a `<g class="statechart__node statechart__node--<type>">` with the id `sc-<dom id>`, where the dom id is the state's dotted path with anything that isn't alphanumeric, `_` or `-` replaced by `-` (`Sourced::UI::MachineChart.dom_id(path)`). For example, `planning.flight.initial` becomes `sc-planning-flight-initial`. Use these ids to handle clicks on a state:

```ruby
div(data: { 'on:click' => "evt.target.closest('.statechart__node') && @get('/states/' + evt.target.closest('.statechart__node').id.slice(3))" }) do
  render Sourced::UI::Components::Statechart.new(chart)
end
```

State classes: `is-active`, `is-visited`, and `is-inactive` or `is-done` on regions. Transitions the machine can take next get `is-live`.

#### Legend and styles

`Sourced::UI::Components::StatechartLegend.new` renders a key to the chart's shapes, colours and lines. It draws each swatch with the chart's own classes.

The styles for both components are in the dashboard's stylesheet, `lib/sourced/ui/dashboard/assets/stylesheets/styles.css`, under the `.statechart` and `.legend` rules. The dashboard serves this file at `/stylesheets/styles.css`. Outside the dashboard, include that file or copy those rules into your own CSS. The SVG sets a `--sc-w` custom property to its natural width, so the stylesheet can scale it to its container without enlarging it past a readable size.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/sourced-ui.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

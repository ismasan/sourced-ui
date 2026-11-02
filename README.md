# Sourced::UI

TODO: Delete this and the text below, and describe your gem

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/sourced/ui`. To experiment with that code, run `bin/console` for an interactive prompt.

## Installation

TODO: Replace `UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG` with your gem name right after releasing it to RubyGems.org. Please do not do it earlier due to security reasons. Alternatively, replace this section with instructions to install your gem from git if you don't plan to release to RubyGems.org.

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG
```

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

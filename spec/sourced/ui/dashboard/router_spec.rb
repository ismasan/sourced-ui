# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

require 'sourced/ui/dashboard'
require_relative '../../../support/spec_light'
require_relative '../../../support/machine_helpers'
require_relative '../../../support/spec_trip'
require 'async'

RSpec.describe Sourced::UI::Dashboard::App do
  include Rack::Test::Methods
  include MachineHelpers

  def app
    Sourced::UI::Dashboard::App
  end

  RouterTestEvent = Sourced::Event.define('router_test.event') do
    attribute :thing_id, String
  end

  class TestProjector < Sourced::Projector::EventSourced
    partition_by :thing_id

    context do
      {}
    end

    evolve RouterTestEvent do |state, _event|
      state
    end

    sync do |state:, messages:, **|
      # no-op
    end
  end

  module RouterTestShop
    class Orders < TestProjector; end
    class Carts < TestProjector; end
  end

  before(:all) do
    Sourced.reset!
    Sourced.config.config!('store.install_tables') { true }
    Sourced.config.config!('workers.count') { 0 }
    Sourced.register(TestProjector)
    Sourced.register(SpecLight)
    Sourced.register(SpecTrip)
    Sourced.register(RouterTestShop::Orders)
    Sourced.register(RouterTestShop::Carts)
    Sourced.start!

    store = Sourced.store
    events = 3.times.map { RouterTestEvent.new(payload: { thing_id: 't1' }) }
    store.append(events)
  end

  after(:all) do
    Sourced.teardown!
    Sourced.reset!
  end

  # Move a group as a worker does, through Store#updating_consumer_group
  # and the GroupUpdater it yields.
  def fail_group(reactor, error)
    Sourced.store.updating_consumer_group(reactor.group_id) { it.fail(exception: error) }
  end

  def retry_group(reactor, error, at: Time.now + 60)
    Sourced.store.updating_consumer_group(reactor.group_id) { it.retry(at, exception: error) }
  end

  def error(klass, message, backtrace = [])
    klass.new(message).tap { it.set_backtrace(backtrace) }
  end

  # Back to active, clearing its error context, from wherever an example left it.
  def activate_group(reactor)
    Sourced.start_consumer_group(reactor)
  rescue Sourced::Store::InvalidConsumerGroupTransitionError
    nil # active already
  end

  describe 'GET /' do
    it 'returns 200 with text/html' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end
  end

  describe 'GET /log' do
    it 'returns 200 with text/html' do
      get '/log'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end
  end

  describe 'GET /log/:position' do
    it 'returns 200 with text/html' do
      get '/log/1'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end
  end

  describe 'GET /offsets' do
    it 'returns 200 with text/html' do
      get '/offsets'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end
  end

  describe 'GET /topology' do
    it 'returns 200 with text/html' do
      get '/topology'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end
  end

  describe 'POST /commands' do
    def post_command(type, group_id = TestProjector.group_id)
      post '/commands', command: { type: "sourced.consumer_groups.#{type}", payload: { group_id: } }
    end

    it 'stops, resets and starts a consumer group with 204' do
      post_command 'stop'
      expect(last_response.status).to eq(204)
      post_command 'reset'
      expect(last_response.status).to eq(204)
      post_command 'start'
      expect(last_response.status).to eq(204)
    end

    it "refuses with 409 a command the group's status doesn't accept" do
      post_command 'start'
      expect(last_response.status).to eq(409)
      expect(last_response.body).to include("it's active")
    end

    it 'returns 404 for unknown command types' do
      post '/commands', command: { type: 'unknown.command', payload: {} }
      expect(last_response.status).to eq(404)
    end
  end

  describe 'trailing slashes' do
    it 'matches /log/ the same as /log' do
      get '/log/'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end

    it 'matches /log/1/ the same as /log/1' do
      get '/log/1/'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end

    it 'matches /topology/ the same as /topology' do
      get '/topology/'
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/html')
    end
  end

  describe 'GET /reactors/:group_id' do
    it 'links each consumer group to its reactor page' do
      get '/'
      expect(last_response.body).to include('/reactors/test_projector"', '/reactors/spec_light"')
    end

    it "greys out a stored group no registered reactor has, with nothing to act on" do
      Sourced.store.register_consumer_group('legacy_payroll', label: 'Legacy::Payroll')
      get '/'
      card = last_response.body[/<div id="group-legacy_payroll".*?<\/div><\/div><\/div>/m]

      expect(card).to include('consumer-unregistered', '>not registered<', '>Legacy::Payroll<')
      expect(card).not_to include('<form', '<a ')
      expect(last_response.body).to include('href="http://example.org/reactors/test_projector"')
    end

    describe 'consumer group cards' do
      after { activate_group(TestProjector) }

      def card
        get '/'
        last_response.body[/<div id="group-test_projector".*?<div class="stream-bar">/m]
      end

      it 'offers an active group Stop only' do
        expect(card).to include('consumer-active', '>active<', '>Stop<')
        expect(card).not_to include('>Resume<', '>Reset<')
      end

      it 'offers a stopped group Resume and Reset, with its stop message' do
        Sourced.stop_consumer_group(TestProjector, 'deploying')
        expect(card).to include('consumer-stopped', '>stopped<', '>Resume<', '>Reset<', 'deploying')
        expect(card).not_to include('>Stop<')
      end

      it 'offers a failed group Resume, Stop and Reset, with its error' do
        fail_group(TestProjector, error(RuntimeError, 'boom'))
        expect(card).to include('consumer-failed', '>failed<', '>Resume<', '>Stop<', '>Reset<', 'RuntimeError: boom')
      end

      it 'offers a retrying group Retry now and Stop, with its error and next attempt' do
        2.times { retry_group(TestProjector, error(IOError, 'flaky')) }
        expect(card).to include('consumer-retrying', '>retrying<', '>Retry now<', '>Stop<', 'IOError: flaky', 'retry #2')
        expect(card).not_to include('>Reset<', '>Resume<')
      end
    end

    describe 'failure card' do
      after { activate_group(TestProjector) }

      it "shows a failed group's exception and backtrace, collapsed, on its reactor page only" do
        fail_group(TestProjector, error(RuntimeError, 'booom!', ['app/listing.rb:12:in `evolve`', '/gems/sourced/lib/sourced/router.rb:40:in `handle`']))

        get '/reactors/test_projector'
        body = last_response.body
        expect(body).to include('<details id="group-test_projector-failure" class="failure-details" data-preserve-attr="open">')
        # In a card of its own, after the group's: its progress bar, then the card, close first.
        expect(body).to match(%r{<div class="upper-range"[^>]*><div class="tooltip">[^<]*</div></div></div></div><details id="group-test_projector-failure"})
        expect(body).to include('>2 frames<', '<strong>RuntimeError</strong>: booom!', 'app/listing.rb:12:in `evolve`')
        expect(body).to match(%r{<li class="is-gem">/gems/sourced/lib/sourced/router.rb})

        get '/'
        expect(last_response.body).not_to include('failure-details')
      end

      it "renders only a hidden placeholder for a group that isn't failed, even with a stored exception" do
        retry_group(TestProjector, error(IOError, 'flaky'))

        get '/reactors/test_projector'
        expect(last_response.body).to include('<div id="group-test_projector-failure" hidden>')
        expect(last_response.body).not_to include('failure-details')
      end
    end

    it "shows a reactor's consumer group and the messages it handles" do
      get '/reactors/test_projector'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('TestProjector', 'kind-badge--projector', 'router_test.event', 'thing_id')
      expect(last_response.body).to include('class="event-model"', 'event-model__node--readmodel')
      expect(last_response.body).to include('data-bind:schemas', 'em-arrow-schemas', '>thing_id<')
    end

    it "shows a machine's statechart, its states and their commands" do
      get '/reactors/spec_light'
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to include('kind-badge--machine', 'class="statechart"', 'Transitions')
      expect(body).to include('/reactors/spec_light/states/on"', '>Dim<')
      expect(body).to include('data-mermaid="stateDiagram-v2', '>Copy Mermaid code<')
      expect(body).not_to match(/is-active" id="sc-/)
    end

    it 'lights a picked state, with what it accepts and refuses' do
      get '/reactors/spec_light/states/on'
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to match(/is-active" id="sc-on"/)
      expect(body).to include('Accepts', 'Refuses', '>Install<')
      # What it takes there, as an event model: Dim appends Dimmed and stays.
      expect(body).to include('class="event-model"', '>Dimmed<', '>stays<')
    end

    it "streams updates to the reactor's consumer group card" do
      get '/reactors/test_projector'
      expect(last_response.body).to include('id="group-test_projector"', "/reactors/test_projector/updates')")

      get '/reactors/Nope/updates'
      expect(last_response.status).to eq(404)
    end

    it "returns 404 for a reactor or state that doesn't exist" do
      get '/reactors/Nope'
      expect(last_response.status).to eq(404)
      get '/reactors/spec_light/states/nope'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /reactors/:group_id/instance' do
    # A light installed, switched on and dimmed: each command, then what it
    # appended, caused by it.
    before(:all) do
      keys = { light_id: 'lamp-1' }
      [SpecLight::Install, SpecLight::Toggle, SpecLight::Dim].each { Sourced.handle!(SpecLight, it.new(payload: keys)) }
      Sourced.store.append([SpecLight::Install.new(payload: { light_id: 'lamp-2' })])
      @positions = Sourced.store.read_partition(keys, handled_types: %w[spec_light.runtime.off spec_light.runtime.on])
                                .messages.to_h { [it.type.split('.').last, it.position] }
    end

    def instance_page(query, env = {})
      get "/reactors/spec_light/instance?#{Rack::Utils.build_query(query)}", {}, env
      last_response.body
    end

    it "offers a form for the machine's partition keys on its page" do
      get '/reactors/spec_light'
      expect(last_response.body).to include(
        '<form method="get" action="http://example.org/reactors/spec_light/instance"',
        'name="light_id" required'
      )
    end

    it 'lights where the instance is at the latest, with its messages, and follows it' do
      body = instance_page(light_id: 'lamp-1')
      expect(last_response.status).to eq(200)
      expect(body).to match(/is-active" id="sc-on"/)
      expect(body).to include('Events (3)', '>→ off<', '>→ on<', '>dimmed<', 'The latest. Following.')
      # Its commands aren't in the feed: they're in what it accepts.
      expect(body[/<ol class="timeline">.*?<\/ol>/m]).not_to include('event-card command')
      # A state change reads as where it went, not as its event's type.
      expect(body).not_to include('>runtime.on<')
      expect(body).not_to include('lamp-2')
      # What it accepts there.
      expect(body).to include('>Toggle<', '>Dim<', '>Break<')
      expect(body[/Refuses.*?<\/ul>/m]).to include('>Install<')
      expect(body).to include("/reactors/spec_light/instance/updates?light_id=lamp-1&after=")
    end

    it 'travels back to a message: the instance as it was once evolved up to it' do
      body = instance_page(light_id: 'lamp-1', at: @positions['off'])
      expect(body).to match(/is-active" id="sc-off"/)
      expect(body).not_to match(/is-active" id="sc-on"/)
      expect(body).to include("As of position #{@positions['off']}.", 'Back to latest', 'is-future')
      expect(body).to match(/href="[^"]*at=#{@positions['off']}"[^>]*class="timeline__link" aria-current="true"/)
      expect(body).not_to include('instance/updates')
    end

    it "marks a machine's state changes apart from its data events, in its feed and in the log" do
      body = instance_page(light_id: 'lamp-1')
      feed = body[/<ol class="timeline">.*?<\/ol>/m]
      expect(feed).to match(/class="event-card state[^"]*">[^\n]*?>→ on</)
      expect(feed).to match(/class="event-card event[^"]*">[^\n]*?>dimmed</)
      # Each with the command it was appended for.
      expect(feed).to match(/>dimmed<\/span><span class="feed-trigger"[^>]*>by <span class="feed-trigger__name">dim</)
      expect(feed).to match(/>→ on<\/span><span class="feed-trigger"[^>]*>by <span class="feed-trigger__name">toggle</)
      # The latest first, down to where it starts.
      expect(feed.scan(/class="event-type">([^<]*)</).flatten).to eq(['dimmed', '→ on', '→ off', 'Start'])

      get "/log/#{@positions['on']}"
      expect(last_response.body).to include('class="event-card fade-in state"', 'class="event-card fade-in command"')
    end

    it 'steps to the older and newer event with arrows, disabled where there are none' do
      nav = ->(body) { body[%r{<span class="pagination feed-nav">.*?</span>}m].scan(/<button[^>]*>/) }

      older, newer = nav.(instance_page(light_id: 'lamp-1'))
      expect(older).to include("at=#{@positions['on']}") # dimmed is latest; on is before it
      expect(newer).to include('disabled')

      older, newer = nav.(instance_page(light_id: 'lamp-1', at: @positions['off']))
      expect(older).to include('at=0')
      expect(newer).to include("at=#{@positions['on']}")

      older, newer = nav.(instance_page(light_id: 'lamp-1', at: 0))
      expect(older).to include('disabled')
      expect(newer).to include("at=#{@positions['off']}")
    end

    it 'travels back to before its first message' do
      body = instance_page(light_id: 'lamp-1', at: 0)
      expect(body).to include('Before its first message.', 'its initial position')
      expect(body).not_to match(/is-active" id="sc-(on|off)"/)
    end

    it "patches the page in over Datastar, pushing the instance's URL with only its partition values" do
      body = instance_page({ light_id: 'lamp-1', at: @positions['on'], datastar: '{"modal":false}' },
                           'HTTP_ACCEPT' => 'text/event-stream')
      expect(body).to include('event: datastar-patch-elements', 'id="reactor"')
      pushed = body[/history\.pushState\([^\n]*/]
      expect(pushed).to include(%("http://example.org/reactors/spec_light/instance?light_id=lamp-1&at=#{@positions['on']}"))
      expect(pushed).not_to include('datastar=')
    end

    it 'shows a partition with no messages where the machine starts' do
      body = instance_page(light_id: 'nope')
      expect(last_response.status).to eq(200)
      expect(body).to include('Events (0)', 'No messages yet')
    end

    it 'draws an instance of a machine with nested and parallel states' do
      keys = { trip_id: 'trip-1' }
      commands = [SpecTrip::Start, SpecTrip::ChooseFlight].map { it.new(payload: keys) }
      started, chosen = decided(SpecTrip, keys, *commands)
      Sourced.store.append([commands[0], *started, commands[1], *chosen].compact)

      get '/reactors/spec_trip/instance?trip_id=trip-1'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/statechart__node--parallel is-active" id="sc-planning"/)
      expect(last_response.body).to include('planning.flight.flight_chosen')
    end

    # Its body streams for as long as the browser follows, in an Async
    # reactor (Sidereal streams with Datastar::AsyncExecutor): read its
    # first patch off the socket, then hang up.
    it 'follows the instance: patches it in as messages arrive after the position it was rendered at' do
      env = Rack::MockRequest.env_for('/reactors/spec_light/instance/updates?light_id=lamp-1&after=0',
                                      'HTTP_ACCEPT' => 'text/event-stream')
      status, _headers, body = app.call(env)
      expect(status).to eq(200)

      chunk = +''
      Sync do |task|
        reader, writer = IO.pipe
        streaming = task.async { body.call(writer) }
        task.with_timeout(5) { chunk << reader.readpartial(65_536) until chunk.include?('</aside>') }
      ensure
        streaming&.stop
        [reader, writer].each { it&.close unless it&.closed? }
      end
      expect(chunk).to include('event: datastar-patch-elements', 'id="machine-instance"', 'Events (3)')
    end

    it "refuses missing partition values, and reactors that aren't machines" do
      instance_page({})
      expect(last_response.status).to eq(400)
      get '/reactors/test_projector/instance?thing_id=t1'
      expect(last_response.status).to eq(404)
      get '/reactors/spec_light/instance/updates'
      expect(last_response.status).to eq(400)
    end
  end

  describe 'consumer groups by namespace' do
    def namespace_box
      get '/'
      last_response.body[%r{<details id="namespace-router_test_shop".*?</details>}m]
    end

    it "boxes groups sharing their group id's first segment, collapsed, titled by their module" do
      box = namespace_box

      expect(box).to include('class="namespace namespace-ok"', 'data-preserve-attr="open"', '>RouterTestShop<', '>2 groups<')
      expect(box).not_to include(' open')
      expect(box).to include('id="group-router_test_shop-orders"', '>RouterTestShop::Orders<', 'id="group-router_test_shop-carts"')
      # A one-segment group id stands alone.
      expect(last_response.body).not_to match(%r{<details[^>]*>(?:(?!</details>).)*id="group-test_projector"}m)
    end

    it "serves a namespaced reactor's page at its dotted group id" do
      get '/reactors/router_test_shop.orders'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('<h1>RouterTestShop::Orders</h1>', '>router_test_shop.orders<')
    end

    it 'says how many of its groups are stopped, so a collapsed box shows it' do
      Sourced.stop_consumer_group(RouterTestShop::Carts)
      box = namespace_box

      expect(box).to include('namespace-stopped', 'namespace-badge--stopped', '>1 stopped<')
    ensure
      Sourced.start_consumer_group(RouterTestShop::Carts)
    end

    it 'counts failed groups apart from stopped ones, and tints the box as failed' do
      Sourced.stop_consumer_group(RouterTestShop::Carts)
      fail_group(RouterTestShop::Orders, error(RuntimeError, 'boom'))
      box = namespace_box

      expect(box).to include('namespace namespace-failed', '>1 failed<', '>1 stopped<')
    ensure
      activate_group(RouterTestShop::Orders)
      activate_group(RouterTestShop::Carts)
    end
  end

  describe 'GET /nonexistent' do
    it 'returns 404' do
      get '/nonexistent'
      expect(last_response.status).to eq(404)
    end
  end
end

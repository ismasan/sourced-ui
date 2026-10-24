# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

require 'sourced/ui/dashboard'
require_relative '../../../support/spec_light'

RSpec.describe Sourced::UI::Dashboard::App do
  include Rack::Test::Methods

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
    it 'handles sourced.ui.resume_consumer_group with 204' do
      post '/commands', command: {
        type: 'sourced.ui.resume_consumer_group',
        payload: { group_id: TestProjector.group_id }
      }
      expect(last_response.status).to eq(204)
    end

    it 'handles sourced.ui.stop_consumer_group with 204' do
      post '/commands', command: {
        type: 'sourced.ui.stop_consumer_group',
        payload: { group_id: TestProjector.group_id }
      }
      expect(last_response.status).to eq(204)
    end

    it 'handles sourced.ui.reset_consumer_group with 204' do
      post '/commands', command: {
        type: 'sourced.ui.reset_consumer_group',
        payload: { group_id: TestProjector.group_id }
      }
      expect(last_response.status).to eq(204)
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

      expect(box).to include('namespace-halted', '>1 stopped<')
    ensure
      Sourced.start_consumer_group(RouterTestShop::Carts)
    end
  end

  describe 'GET /nonexistent' do
    it 'returns 404' do
      get '/nonexistent'
      expect(last_response.status).to eq(404)
    end
  end
end

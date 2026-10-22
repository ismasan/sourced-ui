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

  before(:all) do
    Sourced.reset!
    Sourced.config.config!('store.install_tables') { true }
    Sourced.config.config!('workers.count') { 0 }
    Sourced.register(TestProjector)
    Sourced.register(SpecLight)
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
      expect(last_response.body).to include('/reactors/TestProjector"', '/reactors/SpecLight"')
    end

    it "shows a reactor's consumer group and the messages it handles" do
      get '/reactors/TestProjector'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('TestProjector', 'kind-badge--projector', 'router_test.event', 'thing_id')
      expect(last_response.body).to include('class="event-model"', 'event-model__node--readmodel')
      expect(last_response.body).to include('data-bind:schemas', 'em-arrow-schemas', '>thing_id<')
    end

    it "shows a machine's statechart, its states and their commands" do
      get '/reactors/SpecLight'
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to include('kind-badge--machine', 'class="statechart"', 'Transitions')
      expect(body).to include('/reactors/SpecLight/states/on"', '>Dim<')
      expect(body).to include('data-mermaid="stateDiagram-v2', '>Copy Mermaid code<')
      expect(body).not_to match(/is-active" id="sc-/)
    end

    it 'lights a picked state, with what it accepts and refuses' do
      get '/reactors/SpecLight/states/on'
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to match(/is-active" id="sc-on"/)
      expect(body).to include('Accepts', 'Refuses', '>Install<')
      # What it takes there, as an event model: Dim appends Dimmed and stays.
      expect(body).to include('class="event-model"', '>Dimmed<', '>stays<')
    end

    it "streams updates to the reactor's consumer group card" do
      get '/reactors/TestProjector'
      expect(last_response.body).to include('id="group-TestProjector"', "/reactors/TestProjector/updates')")

      get '/reactors/Nope/updates'
      expect(last_response.status).to eq(404)
    end

    it "returns 404 for a reactor or state that doesn't exist" do
      get '/reactors/Nope'
      expect(last_response.status).to eq(404)
      get '/reactors/SpecLight/states/nope'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /nonexistent' do
    it 'returns 404' do
      get '/nonexistent'
      expect(last_response.status).to eq(404)
    end
  end
end

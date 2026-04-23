# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

require 'sourced/ui/dashboard'

RSpec.describe Sourced::UI::Dashboard::App do
  include Rack::Test::Methods

  def app
    Sourced::UI::Dashboard::App
  end

  TestEvent = Sourced::Event.define('test.event') unless defined?(TestEvent)

  class TestProjector < Sourced::Projector::EventSourced
    partition_by :id

    state do |_partition_values|
      {}
    end

    evolve TestEvent do |state, _event|
      state
    end

    sync do |state:, messages:, **|
      # no-op
    end
  end

  before(:all) do
    Sourced.reset!
    Sourced.configure { |_c| }
    Sourced.register(TestProjector)

    store = Sourced.store
    events = 3.times.map { TestEvent.new }
    store.append(events)
  end

  after(:all) do
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

  describe 'GET /nonexistent' do
    it 'returns 404' do
      get '/nonexistent'
      expect(last_response.status).to eq(404)
    end
  end
end

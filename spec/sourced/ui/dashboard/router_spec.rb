# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sourced/ccc'
require 'sourced/ui/dashboard'

RSpec.describe Sourced::UI::Dashboard::App do
  include Rack::Test::Methods

  def app
    Sourced::UI::Dashboard::App
  end

  TestEvent = Sourced::CCC::Event.define('test.event') unless defined?(TestEvent)

  class TestProjector < Sourced::CCC::Projector::EventSourced
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
    Sourced::CCC.reset!
    Sourced::CCC.configure { |_c| }
    Sourced::CCC.register(TestProjector)

    store = Sourced::CCC.store
    events = 3.times.map { TestEvent.new }
    store.append(events)
  end

  after(:all) do
    Sourced::CCC.reset!
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

  describe 'POST /consumer-groups/resume' do
    it 'returns 204' do
      post '/consumer-groups/resume', group_id: TestProjector.group_id
      expect(last_response.status).to eq(204)
    end
  end

  describe 'POST /consumer-groups/stop' do
    it 'returns 204' do
      post '/consumer-groups/stop', group_id: TestProjector.group_id
      expect(last_response.status).to eq(204)
    end
  end

  describe 'POST /consumer-groups/reset' do
    it 'returns 204' do
      post '/consumer-groups/reset', group_id: TestProjector.group_id
      expect(last_response.status).to eq(204)
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
      expect(last_response.content_type).to include('text/html')
    end
  end
end

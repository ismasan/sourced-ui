# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sourced/ui/router'

class TestRouter < Sourced::UI::Router
  get '/' do
    [200, { 'Content-Type' => 'text/plain' }, ['root']]
  end

  get '/items' do
    [200, { 'Content-Type' => 'text/plain' }, ['items']]
  end

  get '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["item:#{id}"]]
  end

  get '/items/:id/comments/:comment_id' do |id:, comment_id:|
    [200, { 'Content-Type' => 'text/plain' }, ["item:#{id}:comment:#{comment_id}"]]
  end

  post '/items' do
    [201, { 'Content-Type' => 'text/plain' }, ['created']]
  end

  put '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["updated:#{id}"]]
  end

  patch '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["patched:#{id}"]]
  end

  delete '/items/:id' do |id:|
    [200, { 'Content-Type' => 'text/plain' }, ["deleted:#{id}"]]
  end

  redirect '/old', '/items'

  get '/context' do
    [200, { 'Content-Type' => 'text/plain' }, ["method:#{request.request_method}"]]
  end

  callable_handler = ->(req, params) {
    [200, { 'Content-Type' => 'text/plain' }, ["callable:#{params[:id]}:#{req.request_method}"]]
  }
  get '/callable/:id', callable_handler
end

RSpec.describe Sourced::UI::Router do
  include Rack::Test::Methods

  def app
    TestRouter
  end

  describe 'static routes' do
    it 'GET / returns 200' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('root')
    end

    it 'GET /items returns 200' do
      get '/items'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('items')
    end
  end

  describe 'parameterized routes' do
    it 'extracts a single param' do
      get '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42')
    end

    it 'extracts multiple params' do
      get '/items/42/comments/7'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42:comment:7')
    end
  end

  describe 'HTTP methods' do
    it 'POST' do
      post '/items'
      expect(last_response.status).to eq(201)
      expect(last_response.body).to eq('created')
    end

    it 'PUT' do
      put '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('updated:42')
    end

    it 'PATCH' do
      patch '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('patched:42')
    end

    it 'DELETE' do
      delete '/items/42'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('deleted:42')
    end
  end

  describe 'trailing slashes' do
    it 'matches static route with trailing slash' do
      get '/items/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('items')
    end

    it 'matches parameterized route with trailing slash' do
      get '/items/42/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42')
    end

    it 'matches nested parameterized route with trailing slash' do
      get '/items/42/comments/7/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('item:42:comment:7')
    end
  end

  describe 'redirects' do
    it 'returns 301 with Location header' do
      get '/old'
      expect(last_response.status).to eq(301)
      expect(last_response.headers['Location']).to eq('/items')
    end
  end

  describe '404' do
    it 'returns 404 for unmatched path' do
      get '/nope'
      expect(last_response.status).to eq(404)
    end

    it 'returns 404 for wrong HTTP method' do
      delete '/items'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'request context' do
    it 'exposes the request object to handlers' do
      get '/context'
      expect(last_response.body).to eq('method:GET')
    end

    it 'sets router.params in the env' do
      get '/items/42'
      expect(last_request.env['router.params']).to eq({ id: '42' })
    end
  end

  describe 'callable handler' do
    it 'receives request and params' do
      get '/callable/99'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('callable:99:GET')
    end
  end
end

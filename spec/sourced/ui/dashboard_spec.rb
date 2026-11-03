# frozen_string_literal: true

require 'spec_helper'

require 'rack/test'
require 'sourced/ui/dashboard'

RSpec.describe Sourced::UI::Dashboard do
  # Define a test message type for specs
  TestEvent = Sourced::Event.define('test.event') unless defined?(TestEvent)

  describe '.build_causation_tree' do
    it 'builds tree with common root' do
      e1 = TestEvent.new
      e2 = e1.correlate(TestEvent.new)
      e3 = e2.correlate(TestEvent.new)
      tree = Sourced::UI::Dashboard.build_causation_tree([e1, e2, e3])
      expect(tree.size).to eq(1)
      expect(tree[0].message).to eq(e1)
      expect(tree[0].children[0].message).to eq(e2)
      expect(tree[0].children[0].children[0].message).to eq(e3)
    end

    it 'builds tree with many roots' do
      e1a = TestEvent.new
      e1b = TestEvent.new
      e2 = e1a.correlate(TestEvent.new)
      e3 = e1b.correlate(TestEvent.new)
      tree = Sourced::UI::Dashboard.build_causation_tree([e1a, e2, e3, e1b])
      expect(tree.size).to eq(2)
      expect(tree[0].message).to eq(e1a)
      expect(tree[1].message).to eq(e1b)
      expect(tree[0].children[0].message).to eq(e2)
      expect(tree[1].children[0].message).to eq(e3)
    end

    it 'builds tree with missing original causation message' do
      cid = SecureRandom.uuid
      e1 = TestEvent.new(causation_id: cid, correlation_id: cid)
      e2 = e1.correlate(TestEvent.new)
      e3 = e2.correlate(TestEvent.new)
      tree = Sourced::UI::Dashboard.build_causation_tree([e1, e2, e3])
      expect(tree.size).to eq(1)
      expect(tree[0].message).to eq(e1)
      expect(tree[0].children[0].message).to eq(e2)
      expect(tree[0].children[0].children[0].message).to eq(e3)
    end
  end

  describe '.build_app' do
    include Rack::Test::Methods

    let(:inner) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }
    let(:config) { Sourced::UI::Dashboard::Configuration.new }
    let(:app) { Sourced::UI::Dashboard.build_app(config, inner) }

    it 'returns the app unwrapped when basic auth is not configured' do
      expect(app).to be(inner)
    end

    context 'with basic auth' do
      before { config.basic_auth('admin', 's3cret') }

      it 'rejects requests without credentials' do
        get '/'
        expect(last_response.status).to eq(401)
        expect(last_response.headers['www-authenticate']).to eq('Basic realm="Sourced Dashboard"')
      end

      it 'rejects wrong credentials' do
        basic_authorize 'admin', 'nope'
        get '/'
        expect(last_response.status).to eq(401)
      end

      it 'allows correct credentials' do
        basic_authorize 'admin', 's3cret'
        get '/'
        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq('ok')
      end

      it 'uses a custom realm' do
        config.basic_auth('admin', 's3cret', realm: 'Ops')
        get '/'
        expect(last_response.headers['www-authenticate']).to eq('Basic realm="Ops"')
      end
    end

    it 'raises on blank credentials' do
      expect { config.basic_auth('admin', '') }.to raise_error(ArgumentError)
      expect { config.basic_auth(nil, 'x') }.to raise_error(ArgumentError)
    end
  end
end

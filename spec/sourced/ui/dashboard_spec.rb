# frozen_string_literal: true

require 'spec_helper'

require 'sourced/ui/dashboard'

RSpec.describe Sourced::UI::Dashboard do
  # Define a test message type for specs
  TestEvent = Sourced::CCC::Event.define('test.event') unless defined?(TestEvent)

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
end

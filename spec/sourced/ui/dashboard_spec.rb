# frozen_string_literal: true

require 'spec_helper'

require 'sourced/ui/dashboard'

RSpec.describe Sourced::UI::Dashboard do
  describe '.build_causation_tree' do
    it 'builds tree with common root' do
      e1_id = SecureRandom.uuid
      e1 = Sourced::Message.new(id: e1_id)
      e2 = e1.correlate(Sourced::Message.new)
      e3 = e2.correlate(Sourced::Message.new)
      tree = Sourced::UI::Dashboard.build_causation_tree([e1, e2, e3])
      expect(tree.size).to eq(1)
      expect(tree[0].message).to eq(e1)
      expect(tree[0].children[0].message).to eq(e2)
      expect(tree[0].children[0].children[0].message).to eq(e3)
    end

    it 'builds tree with many roots' do
      e1_id = SecureRandom.uuid
      e2_id = SecureRandom.uuid
      e1a = Sourced::Message.new(id: e1_id)
      e1b = Sourced::Message.new(id: e2_id)
      e2 = e1a.correlate(Sourced::Message.new)
      e3 = e1b.correlate(Sourced::Message.new)
      tree = Sourced::UI::Dashboard.build_causation_tree([e1a, e2, e3, e1b])
      expect(tree.size).to eq(2)
      expect(tree[0].message).to eq(e1a)
      expect(tree[1].message).to eq(e1b)
      expect(tree[0].children[0].message).to eq(e2)
      expect(tree[1].children[0].message).to eq(e3)
    end

    it 'builds tree with missing original causation event (command not saved)' do
      cid = SecureRandom.uuid
      e1_id = SecureRandom.uuid
      e1 = Sourced::Message.new(id: e1_id, causation_id: cid)
      e2 = e1.correlate(Sourced::Message.new)
      e3 = e2.correlate(Sourced::Message.new)
      tree = Sourced::UI::Dashboard.build_causation_tree([e1, e2, e3])
      expect(tree.size).to eq(1)
      expect(tree[0].message).to eq(e1)
      expect(tree[0].children[0].message).to eq(e2)
      expect(tree[0].children[0].children[0].message).to eq(e3)
    end
  end
end

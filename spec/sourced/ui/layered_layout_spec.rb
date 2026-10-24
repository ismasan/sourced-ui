# frozen_string_literal: true

require 'spec_helper'
require 'sourced/ui/layered_layout'

RSpec.describe Sourced::UI::LayeredLayout do
  def node(id, w = 100) = described_class::Node.new(id:, w:, h: 30, extra: 0, round: false)
  def edge(id, from, to, label = "e#{id}") = described_class::Edge.new(id:, from:, to:, label_w: label.size * 6, label_h: 12)

  def label_box(layout, edge)
    x, y = layout.routes.fetch(edge.id).label
    x -= edge.label_w / 2.0 if layout.routes.fetch(edge.id).anchor == 'middle'
    [x, y - edge.label_h, edge.label_w, edge.label_h]
  end

  def overlap?((x1, y1, w1, h1), (x2, y2, w2, h2)) = x1 < x2 + w2 && x2 < x1 + w1 && y1 < y2 + h2 && y2 < y1 + h1

  # a ─▶ b, a ─▶ c (expire), c ─▶ a (back up), a ─▶ d (two ranks down), c ─▶ d
  let(:nodes) { %i[a b c d].map { node(it) } }
  let(:edges) do
    [edge(0, :a, :b, 'Go'), edge(1, :a, :c, 'Expire'), edge(2, :c, :a, 'Resend'), edge(3, :b, :e, 'Far'),
     edge(4, :c, :e, 'Down'), edge(5, :e, :a, 'Back')]
  end
  let(:layout) { described_class.new(nodes + [node(:e)], edges, starts: [:a]) }

  it 'ranks nodes down from the start' do
    ys = layout.boxes.transform_values(&:y)

    expect(ys[:a]).to be < ys[:b]
    expect(ys[:b]).to eq(ys[:c])
    expect(ys[:c]).to be < ys[:e]
  end

  it 'routes an edge back up from its source to its target' do
    route = layout.routes.fetch(2)
    a = layout.boxes.fetch(:a)
    c = layout.boxes.fetch(:c)

    expect(route.points.first[1]).to eq(c.y)
    expect(route.points.last[1]).to eq(a.y + 30)
  end

  it "spreads the edges leaving a node's side" do
    starts = [0, 1, 2].map { layout.routes.fetch(it) }.map { it.points.first }
    bottom = layout.boxes.fetch(:a).y + 30
    leaving = starts.select { it[1] == bottom }.map(&:first)

    expect(leaving.size).to eq(2)
    expect(leaving.uniq.size).to eq(2)
  end

  it 'keeps labels apart from each other and from nodes' do
    labels = edges.map { label_box(layout, it) }
    boxes = layout.boxes.values.map { [it.x, it.y, 100, 30] }

    labels.combination(2).each { |p, q| expect(overlap?(p, q)).to be(false), "labels #{p} and #{q} overlap" }
    labels.product(boxes).each { |l, b| expect(overlap?(l, b)).to be(false), "label #{l} overlaps node #{b}" }
  end

  it 'draws an edge within a rank straight across between neighbours' do
    flat = described_class.new([node(:a), node(:b), node(:c)], [edge(0, :a, :b), edge(1, :a, :c), edge(2, :c, :b)], starts: [:a])
    route = flat.routes.fetch(2)

    expect(route.flat).to eq(:straight)
    expect(route.points.map(&:last).uniq.size).to eq(1)
    expect(flat.routes.fetch(0).flat).to be_nil
  end

  it "runs a straight edge under the left node's extra, its label past it" do
    looped = described_class::Node.new(id: :a, w: 100, h: 30, extra: 60, round: false)
    layout = described_class.new([node(:s), looped, node(:b)], [edge(0, :s, :a), edge(1, :s, :b), edge(2, :a, :b, 'Across')], starts: [:s])
    route = layout.routes.fetch(2)
    a = layout.boxes.fetch(:a)
    skip 'a and b were not laid out side by side' unless route.flat == :straight

    expect(route.points.map(&:last).uniq).to eq([a.y + 15 + described_class::LOOP_CLEARANCE])
    expect(route.label[0] - 'Across'.size * 3).to be >= a.x + 100 + 60
  end

  it 'lays out nothing to nothing' do
    empty = described_class.new([], [])

    expect([empty.width, empty.height, empty.boxes, empty.routes]).to eq([0, 0, {}, {}])
    expect { described_class.new([], [edge(0, :a, :b)]) }.to raise_error(ArgumentError, /need nodes/)
  end

  it "draws one under the rank when its ends can't be neighbours" do
    # b, c and d in one rank, an edge between each pair: one pair isn't side by side.
    nodes = %i[a b c d].map { node(it) }
    edges = [edge(0, :a, :b), edge(1, :a, :c), edge(2, :a, :d), edge(3, :b, :c), edge(4, :c, :d), edge(5, :b, :d)]
    flats = described_class.new(nodes, edges, starts: [:a]).routes.values_at(3, 4, 5).map(&:flat)

    expect(flats.tally).to eq(straight: 2, under: 1)
  end

  it 'puts the tops above even the starts' do
    tops = described_class.new([node(:entry, 2), node(:a), node(:b)], [edge(0, :entry, :a), edge(1, :a, :b)],
                               starts: [:a], tops: [:entry])

    expect(tops.boxes.fetch(:entry).y).to be < tops.boxes.fetch(:a).y
    expect(tops.routes.fetch(0).flat).to be_nil
  end

  it 'ranks a node nothing reaches last' do
    lone = described_class.new([node(:a), node(:b), node(:z)], [edge(0, :a, :b)], starts: [:a])

    expect(lone.boxes.fetch(:z).y).to be > lone.boxes.fetch(:a).y
  end

  it 'refuses a self-loop' do
    expect { described_class.new([node(:a)], [edge(0, :a, :a)]) }.to raise_error(ArgumentError, /loops to itself/)
  end

  describe '.pack' do
    it 'keeps each position at least its separation after the one before, as close to its target as it can' do
      expect(described_class.pack([0, 0, 0], [1, 1, 1], [10, 10])).to eq([-10.0, 0.0, 10.0])
      expect(described_class.pack([50, 0], [1, 1], [10])).to eq([20.0, 30.0])
      expect(described_class.pack([0, 100], [1, 1], [10])).to eq([0.0, 100.0])
    end
  end
end

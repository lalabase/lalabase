# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::Navigation — flat page list → nested folder/page tree.
# Type: Service spec.
# Why:  The tree is how users find pages; folder grouping, ordering, the active
#       page and the "changed since last visit" flag (DT5) must be correct.
RSpec.describe Documentation::Navigation do
  def page(path, title = nil)
    instance_double(DocumentationPage, path: path, title: title)
  end

  it 'groups nested paths into folders, folders before pages' do
    nodes = described_class.new([page('guide/setup.md', 'Setup'), page('intro.md', 'Intro')]).nodes

    expect(nodes.first).to be_dir
    expect(nodes.first.label).to eq('Guide')
    expect(nodes.first.children.map(&:label)).to eq(['Setup'])
    expect(nodes.last).not_to be_dir
    expect(nodes.last.label).to eq('Intro')
  end

  it 'falls back to a humanized filename when a page has no title' do
    nodes = described_class.new([page('getting-started.md', nil)]).nodes

    expect(nodes.first.label).to eq('Getting Started')
  end

  it 'flags the current page as active' do
    nodes = described_class.new([page('a.md', 'A'), page('b.md', 'B')], current_page_path: 'b.md').nodes

    expect(nodes.find { |n| n.label == 'A' }.active).to be(false)
    expect(nodes.find { |n| n.label == 'B' }.active).to be(true)
  end

  it 'flags pages changed since the last visit' do
    nodes = described_class.new([page('a.md', 'A'), page('b.md', 'B')], changed_paths: ['b.md']).nodes

    expect(nodes.find { |n| n.label == 'A' }.changed).to be(false)
    expect(nodes.find { |n| n.label == 'B' }.changed).to be(true)
  end

  it 'returns an empty list when there are no pages' do
    expect(described_class.new([]).nodes).to eq([])
  end

  it 'orders pages by path regardless of the input order' do
    nodes = described_class.new([page('c.md', 'C'), page('a.md', 'A'), page('b.md', 'B')]).nodes
    expect(nodes.map(&:label)).to eq(%w[A B C])
  end

  it 'nests multiple folder levels' do
    nodes = described_class.new([page('guide/advanced/deep.md', 'Deep')]).nodes

    guide = nodes.first
    advanced = guide.children.first
    expect(guide.label).to eq('Guide')
    expect(advanced).to be_dir
    expect(advanced.label).to eq('Advanced')
    expect(advanced.children.first.label).to eq('Deep')
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What:  ProductKnowledge::Sync, which makes product_knowledge_entries equal to the given rows.
# Type:  Service test with rows built by product_knowledge_row (spec/support/product_knowledge.rb).
# Why:   The table is only trustworthy if it equals the files: new rows in, changed rows
#        updated, vanished rows out, and a second run over the same files writes nothing.
#        A row whose source is no longer registered must go too (fail closed), and the
#        repair (rewrite) must write a row even when its hash claims nothing changed.
RSpec.describe ProductKnowledge::Sync do
  def row(slug, body, locale: 'de')
    product_knowledge_row(slug, body, locale: locale)
  end

  # The write statements against the table while the block runs.
  def writes_during(&)
    statements = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      statements << sql if sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/i) && sql.include?('product_knowledge_entries')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    statements
  end

  it 'inserts every row' do
    result = described_class.call(rows: [row('a', 'Erster Text'), row('b', 'Zweiter Text')])

    expect(ProductKnowledgeEntry.pluck(:slug)).to contain_exactly('a', 'b')
    expect(result.to_h).to eq(written: 2, deleted: 0)
  end

  it 'writes nothing on a second run over the same rows' do
    rows = [row('a', 'Erster Text'), row('b', 'Zweiter Text')]
    described_class.call(rows: rows)

    result = nil
    expect(writes_during { result = described_class.call(rows: rows) }).to be_empty
    expect(result.to_h).to eq(written: 0, deleted: 0)
  end

  it 'updates a changed row in place and leaves the others alone' do
    described_class.call(rows: [row('a', 'Erster Text'), row('b', 'Zweiter Text')])
    id_before = ProductKnowledgeEntry.find_by!(slug: 'b').id

    result = described_class.call(rows: [row('a', 'Erster Text'), row('b', 'Neuer Text')])

    changed = ProductKnowledgeEntry.find_by!(slug: 'b')
    expect([changed.id, changed.body_markdown]).to eq([id_before, 'Neuer Text'])
    expect(result.to_h).to eq(written: 1, deleted: 0)
  end

  it 'rewrites every row on rewrite, even a hand edit whose hash still matches' do
    rows = [row('a', 'Erster Text'), row('b', 'Zweiter Text')]
    described_class.call(rows: rows)
    ProductKnowledgeEntry.where(slug: 'a').update_all(body_markdown: 'von Hand verdorben')

    expect(described_class.call(rows: rows).to_h).to eq(written: 0, deleted: 0)
    expect(described_class.call(rows: rows, rewrite: true).to_h).to eq(written: 2, deleted: 0)
    expect(ProductKnowledgeEntry.find_by!(slug: 'a').body_markdown).to eq('Erster Text')
  end

  it 'keeps the generated search column in step with an update' do
    described_class.call(rows: [row('a', 'Alpha')])
    described_class.call(rows: [row('a', 'Gamma')])

    expect(ProductKnowledgeEntry.exists?(["search_vector @@ to_tsquery('german', 'gamma')"])).to be true
    expect(ProductKnowledgeEntry.exists?(["search_vector @@ to_tsquery('german', 'alpha')"])).to be false
  end

  it 'deletes a row whose text is gone' do
    described_class.call(rows: [row('a', 'Erster Text'), row('b', 'Zweiter Text')])

    result = described_class.call(rows: [row('a', 'Erster Text')])

    expect(ProductKnowledgeEntry.pluck(:slug)).to eq(['a'])
    expect(result.to_h).to eq(written: 0, deleted: 1)
  end

  it 'deletes the rows of a source that is no longer registered' do
    ProductKnowledgeEntry.insert_all([row('old-news', 'Alte Neuigkeit').merge(source: 'changelog')])

    described_class.call(rows: [row('a', 'Erster Text')])

    expect(ProductKnowledgeEntry.pluck(:source, :slug)).to eq([%w[help a]])
  end

  it 'tells the same slug apart by language' do
    described_class.call(rows: [row('a', 'Deutscher Text'), row('a', 'English text', locale: 'en')])

    expect(ProductKnowledgeEntry.order(:locale).pluck(:locale, :body_markdown))
      .to eq([['de', 'Deutscher Text'], ['en', 'English text']])
  end
end

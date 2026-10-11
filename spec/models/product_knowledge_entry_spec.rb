# frozen_string_literal: true

require 'rails_helper'

# What:  ProductKnowledgeEntry, one of Lalabase's own texts as a searchable row.
# Type:  Model test against the real table, generated column and check constraint included.
# Why:   Properties the rest of the feature leans on and nothing else would notice breaking:
#        the table has no tenant (an accidental acts_as_tenant filters every row away
#        without raising), search_vector follows the texts by itself in the row's language,
#        a hit weighs title over description over text, and a third language fails loudly in
#        the database instead of going unindexed.
RSpec.describe ProductKnowledgeEntry do
  describe 'multi-tenancy' do
    it 'is readable without a tenant and from inside any tenant' do
      entry = create(:product_knowledge_entry)
      organisation = create(:organisation)

      ActsAsTenant.with_tenant(nil) { expect(described_class.find_by(id: entry.id)).to eq(entry) }
      ActsAsTenant.with_tenant(organisation) { expect(described_class.find_by(id: entry.id)).to eq(entry) }
    end
  end

  describe 'validations' do
    it 'rejects a source that is not registered' do
      expect(build(:product_knowledge_entry, source: 'self-hosting')).not_to be_valid
    end

    it 'rejects a locale the help does not have' do
      expect(build(:product_knowledge_entry, locale: 'fr')).not_to be_valid
    end

    it 'requires slug, title and content hash' do
      %i[slug title content_hash].each do |column|
        expect(build(:product_knowledge_entry, column => '')).not_to be_valid, "#{column} blank was valid"
      end
    end

    it 'accepts empty texts but not missing ones' do
      expect(build(:product_knowledge_entry, body_text: '', body_markdown: '')).to be_valid
      expect(build(:product_knowledge_entry, body_text: nil)).not_to be_valid
      expect(build(:product_knowledge_entry, body_markdown: nil)).not_to be_valid
    end
  end

  describe 'the locale check constraint' do
    it 'refuses a third language in the database, even past the validations' do
      row = attributes_for(:product_knowledge_entry, locale: 'fr', slug: 'guides/basics/fr')

      expect { described_class.transaction(requires_new: true) { described_class.insert_all([row]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /product_knowledge_entries_locale_check/)
    end
  end

  describe 'search_vector, the generated column' do
    def matches?(entry, config, query)
      described_class.where(id: entry.id)
                     .exists?(['search_vector @@ to_tsquery(?::regconfig, ?)', config, query])
    end

    it 'stems a German row with the german configuration' do
      entry = create(:product_knowledge_entry, locale: 'de', title: 'Zeiten erfassen', body_text: 'Buchungen')

      expect(matches?(entry, 'german', 'zeit')).to be true
      expect(matches?(entry, 'german', 'buchung')).to be true
    end

    it 'stems an English row with the english configuration' do
      entry = create(:product_knowledge_entry, locale: 'en', title: 'Tracking time', body_text: 'Bookings')

      expect(matches?(entry, 'english', 'track')).to be true
      expect(matches?(entry, 'english', 'booking')).to be true
    end

    it 'indexes the description too' do
      entry = create(:product_knowledge_entry, description: 'Einladungen verschicken')

      expect(matches?(entry, 'german', 'einladung')).to be true
    end

    it 'follows a changed text without anyone writing the column' do
      entry = create(:product_knowledge_entry, body_text: 'Alpha')
      entry.update!(body_text: 'Gamma')

      expect(matches?(entry, 'german', 'gamma')).to be true
      expect(matches?(entry, 'german', 'alpha')).to be false
    end

    it 'weighs a hit in the title over the description over the text' do
      in_title = create(:product_knowledge_entry, title: 'Meetings', body_text: 'Etwas anderes')
      in_description = create(:product_knowledge_entry, title: 'Anders', description: 'Meetings', body_text: 'Mehr')
      in_body = create(:product_knowledge_entry, title: 'Etwas anderes', body_text: 'Meetings')

      ranks = described_class.where(id: [in_title.id, in_description.id, in_body.id])
                             .pluck(:id, Arel.sql("ts_rank(search_vector, to_tsquery('german', 'meeting'))")).to_h
      expect(ranks.values_at(in_title.id, in_description.id, in_body.id)).to eq(ranks.values.sort.reverse)
      expect(ranks.values.uniq.size).to eq(3)
    end
  end
end

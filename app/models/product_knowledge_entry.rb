# frozen_string_literal: true

# == Schema Information
#
# Table name: product_knowledge_entries
#
#  id            :uuid             not null, primary key
#  body_markdown :text             not null
#  body_text     :text             not null
#  content_hash  :string           not null
#  description   :text
#  locale        :string           not null
#  published_on  :date
#  search_vector :tsvector
#  section       :string
#  slug          :string           not null
#  source        :string           not null
#  title         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_product_knowledge_entries_on_search_vector       (search_vector) USING gin
#  index_product_knowledge_entries_on_source_locale_slug  (source,locale,slug) UNIQUE
#
# Check Constraints
#
#  product_knowledge_entries_locale_check  (locale IN ('de', 'en'))
#

# One of Lalabase's own texts (a help page; the news join in S3) as a searchable row
# (doc/product_knowledge_plan.md).
#
# GLOBAL table, no acts_as_tenant (D1): every organisation reads the same rows, and the
# assistant reads them from inside an organisation's tenant. An acts_as_tenant here would
# not raise, it would filter every row away (app/models/CLAUDE.md, Falle 3).
#
# Derived, never edited (D3): ProductKnowledge::Sync writes the rows from the files and may
# delete and rebuild them at any time. Readers go through ProductKnowledge::Search, which
# brings the table up to date first. search_vector is a generated column (see the
# migration) and is only ever read in SQL.
class ProductKnowledgeEntry < ApplicationRecord
  validates :source, inclusion: { in: ProductKnowledge::Sources::KEYS }
  validates :locale, inclusion: { in: Docs::Contract::LOCALES }
  validates :slug, :title, :content_hash, presence: true
  # Present but possibly empty: a page that is only a heading has no body text.
  validates :body_markdown, :body_text, exclusion: { in: [nil] }
end

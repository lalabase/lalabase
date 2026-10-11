# frozen_string_literal: true

# Lalabase's own texts (the in-app help, later the news) as one searchable table
# (doc/product_knowledge_plan.md). Deliberately WITHOUT organisation_id: the rows are the
# same for every organisation, and the table is a derived copy of files in the repository
# that ProductKnowledge::Sync can rebuild at any time.
#
# search_vector is a STORED generated column, so it can never drift from the texts. The text
# search configuration follows the row's locale, and a hit weighs more in the title than in
# the description, and more there than in the body (A, B, C).
class CreateProductKnowledgeEntries < ActiveRecord::Migration[8.0]
  SEARCH_VECTOR = <<~SQL.squish
    CASE locale
      WHEN 'de' THEN setweight(to_tsvector('german'::regconfig, coalesce(title, '')), 'A')
                  || setweight(to_tsvector('german'::regconfig, coalesce(description, '')), 'B')
                  || setweight(to_tsvector('german'::regconfig, coalesce(body_text, '')), 'C')
      WHEN 'en' THEN setweight(to_tsvector('english'::regconfig, coalesce(title, '')), 'A')
                  || setweight(to_tsvector('english'::regconfig, coalesce(description, '')), 'B')
                  || setweight(to_tsvector('english'::regconfig, coalesce(body_text, '')), 'C')
    END
  SQL

  def change
    create_table :product_knowledge_entries, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :source, null: false
      t.string :locale, null: false
      t.string :slug, null: false
      t.string :title, null: false
      t.string :section
      t.text :description
      t.text :body_markdown, null: false
      t.text :body_text, null: false
      t.string :content_hash, null: false
      t.date :published_on
      t.virtual :search_vector, type: :tsvector, as: SEARCH_VECTOR, stored: true
      t.timestamps
      # The two languages the help has, the same two ProductKnowledge::Search::CONFIGS and the
      # CASE above know. A third one must fail here, loudly, instead of going unindexed.
      t.check_constraint "locale IN ('de', 'en')", name: 'product_knowledge_entries_locale_check'
    end

    add_index :product_knowledge_entries, %i[source locale slug], unique: true,
                                                                  name: 'index_product_knowledge_entries_on_source_locale_slug'
    add_index :product_knowledge_entries, :search_vector, using: :gin
  end
end

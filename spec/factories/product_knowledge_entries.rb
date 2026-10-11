# frozen_string_literal: true

# Rows built here are not in the help files: a real read syncs the table and deletes them.
# Specs that read them tag themselves :product_knowledge_table_as_given
# (spec/support/product_knowledge.rb).
FactoryBot.define do
  factory :product_knowledge_entry do
    source { ProductKnowledge::Sources::HELP }
    locale { 'de' }
    sequence(:slug) { |n| "guides/basics/page-#{n}" }
    title { 'Eine Hilfeseite' }
    section { 'Grundlagen' }
    description { nil }
    body_markdown { "# #{title}\n\nText der Seite." }
    body_text { "#{title} Text der Seite." }
    content_hash { Digest::SHA256.hexdigest("#{title}#{body_markdown}") }
  end
end

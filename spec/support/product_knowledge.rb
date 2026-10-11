# frozen_string_literal: true

# Product knowledge in specs (doc/product_knowledge_plan.md).
#
# 1. ProductKnowledge::EnsureFresh remembers per PROCESS what it verified. Specs roll the table
#    back after every example, so the memo is forgotten before each one; otherwise an example
#    would trust a table the previous one filled.
# 2. `:product_knowledge_table_as_given` stubs EnsureFresh, for specs that build rows with the
#    factory. Without it the first read syncs the real help and deletes those rows.
# 3. product_knowledge_row builds a source row the way ProductKnowledge::Sources does.
module ProductKnowledgeHelpers
  def product_knowledge_row(slug, body, locale: 'de', title: nil, description: nil)
    ProductKnowledge::Sources.build_row(
      source: ProductKnowledge::Sources::HELP, locale: locale, slug: slug, title: title || slug.titleize,
      section: 'Grundlagen', description: description, body_markdown: body, body_text: body, published_on: nil
    )
  end
end

RSpec.shared_context 'product knowledge table as given' do
  before { allow(ProductKnowledge::EnsureFresh).to receive(:call) }
end

RSpec.configure do |config|
  config.include ProductKnowledgeHelpers
  config.before { ProductKnowledge::EnsureFresh.forget! }
  config.include_context 'product knowledge table as given', :product_knowledge_table_as_given
end

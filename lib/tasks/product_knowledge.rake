# frozen_string_literal: true

# Rewrites product_knowledge_entries from the files by hand (doc/product_knowledge_plan.md).
# Normally not needed: every read brings the table up to date by itself
# (ProductKnowledge::EnsureFresh). This is the repair: it rewrites every row, so a row edited
# by hand is fixed too, and it ignores the release order EnsureFresh keeps.
namespace :product_knowledge do
  desc "Rewrite product_knowledge_entries from Lalabase's help texts (also repairs rows edited by hand)"
  task sync: :environment do
    result = ProductKnowledge::EnsureFresh.call(force: true)
    if result
      puts "Product knowledge: #{result.written} written, #{result.deleted} deleted, " \
           "#{ProductKnowledgeEntry.count} entries."
    else
      puts 'Product knowledge: nothing written. Another process holds the lock, or a language ' \
           'has no help pages; the log says which.'
    end
  end
end

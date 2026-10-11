# frozen_string_literal: true

# Ensures the compiled tree-sitter grammars exist before specs that parse
# TypeScript / TSX. The artifacts live in tmp/ (git-ignored, built per
# environment), so a clean checkout / CI must build them on demand. Shared by
# the extractor and walker specs so the build-or-skip logic lives in ONE place.
module TreeSitterGrammarsHelper
  GRAMMARS = %w[typescript tsx].freeze

  module_function

  def ensure_built!
    grammar = Lalabase::Indexer::Symbols::TreeSitterGrammar
    # Any ONE missing grammar trips the rescue, which rebuilds ALL of them — the
    # build script is all-or-nothing and cheap (~1-2s). Don't "optimize" this to
    # build only the missing one; that would skip the corrupt-build reload below.
    GRAMMARS.each { |name| grammar.library_path(name) }
  rescue Lalabase::Indexer::Symbols::TreeSitterGrammar::NotBuiltError
    system(Rails.root.join('bin/build-tree-sitter-parsers').to_s, exception: true)
    grammar.reset!
    # Load now so a corrupt/partial build fails loudly HERE, not deep in the C
    # binding on the first example (the build above only heals a MISSING artifact).
    GRAMMARS.each { |name| grammar.language(name) }
  end
end

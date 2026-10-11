# frozen_string_literal: true

require 'tree_sitter'

module Lalabase
  module Indexer
    module Symbols
      # Loads compiled tree-sitter grammars (the per-language ".so"/".dylib") and
      # hands back a reusable TreeSitter::Language.
      #
      # Division of labour (kept deliberately split so each concern lives once):
      #   - COMPILING the grammar from its vendored C sources -> bin/build-tree-sitter-parsers
      #   - LOADING the compiled grammar at runtime            -> this module
      #
      # The tree-sitter RUNTIME ships precompiled with the ruby_tree_sitter gem
      # (multi-platform), so no runtime build is needed for it. Only the GRAMMARS
      # are built locally — their compiled artifact is platform-specific and lives
      # in tmp/ (git-ignored), built per environment by the script above. We only
      # commit the C sources (vendor/tree-sitter-*), never the binary.
      module TreeSitterGrammar
        module_function

        # Raised when a grammar is requested before it was compiled. The message
        # points at the fix rather than failing deep inside the C binding.
        class NotBuiltError < StandardError; end

        # Output path convention — MUST match bin/build-tree-sitter-parsers.
        OUTPUT_DIR = Rails.root.join('tmp/tree_sitter')

        # Returns a memoised TreeSitter::Language for the given grammar name
        # (e.g. "typescript"). Language objects are safe to keep and share — unlike
        # Tree / Query / TreeCursor, which the gem warns must stay local — so we
        # cache them to avoid re-opening the shared library for every file.
        def language(name)
          (@languages ||= {})[name.to_s] ||= TreeSitter::Language.load(name.to_s, library_path(name).to_s)
        end

        # Absolute path to the compiled grammar, or NotBuiltError if it is missing.
        def library_path(name)
          path = OUTPUT_DIR.join("libtree-sitter-#{name}.#{library_extension}")
          return path if path.exist?

          raise NotBuiltError,
                "tree-sitter grammar '#{name}' not built at #{path}. Run: bin/build-tree-sitter-parsers"
        end

        # macOS links shared objects as .dylib, Linux (dev VM, CI, prod) as .so.
        def library_extension
          RbConfig::CONFIG['host_os'].match?(/darwin/) ? 'dylib' : 'so'
        end

        # Test seam: drop the memoised languages (e.g. after rebuilding a grammar).
        def reset!
          @languages = {}
        end
      end
    end
  end
end

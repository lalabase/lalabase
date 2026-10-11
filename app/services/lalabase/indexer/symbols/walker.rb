# frozen_string_literal: true

module Lalabase
  module Indexer
    module Symbols
      # Walks the cloned repository and yields per-file symbol arrays. The Job
      # uses this to drive incremental persistence and progress updates.
      #
      # Skips:
      #   - hidden directories (.git, .bundle, node_modules, ...)
      #   - files larger than MAX_FILE_BYTES (avoid OOM on generated code)
      #   - files in SKIP_DIRS (typical noise: tmp/, log/, vendor/)
      class Walker
        MAX_FILE_BYTES = 500_000 # 500 KB — beyond that, generated or vendored
        # Directories we never index. Vendored deps and build artefacts add noise
        # without code that the user reasons about.
        # Single-segment directory names. Hidden dirs (starting with '.') are
        # handled separately via the dotfile rule.
        SKIP_DIRS = %w[
          node_modules vendor tmp log coverage public
          dist build target
        ].freeze
        # Single source of truth for THE INDEXER'S extension → language dispatch:
        # extension → [extractor, kwargs]. Enumeration, the full index
        # (each_file_symbols) and the incremental re-index (symbols_for) all route
        # through it. (TypescriptExtractor also carries its own LANGUAGE /
        # DEFAULT_GRAMMAR defaults for standalone use; the Walker always overrides
        # them via the kwargs below, so the two never disagree in the pipeline.)
        #
        #   language: the tag stored on every symbol (a CodeSymbol::LANGUAGES value).
        #   grammar:  which compiled tree-sitter grammar parses the file. The
        #             `typescript` grammar errors on JSX, so .tsx/.jsx use `tsx`
        #             (a JSX superset that emits the same declaration nodes).
        EXTENSION_REGISTRY = {
          '.rb' => [RubyExtractor, {}],
          '.rake' => [RubyExtractor, {}],
          '.ts' => [TypescriptExtractor, { language: 'typescript', grammar: 'typescript' }],
          '.tsx' => [TypescriptExtractor, { language: 'typescript', grammar: 'tsx' }],
          '.js' => [TypescriptExtractor, { language: 'javascript', grammar: 'typescript' }],
          '.mjs' => [TypescriptExtractor, { language: 'javascript', grammar: 'typescript' }],
          '.cjs' => [TypescriptExtractor, { language: 'javascript', grammar: 'typescript' }],
          '.jsx' => [TypescriptExtractor, { language: 'javascript', grammar: 'tsx' }]
        }.freeze

        def initialize(repo_root)
          @root = Pathname.new(repo_root)
        end

        # @yield [Array<Hash>, String] symbols, repo-relative file_path
        def each_file_symbols
          return enum_for(:each_file_symbols) unless block_given?

          enumerate_files.each do |abs_path|
            rel_path = abs_path.relative_path_from(@root).to_s
            next unless extractor_config(abs_path)

            source = read_safely(abs_path)
            next if source.nil?

            yield build_extractor(abs_path, source: source, rel_path: rel_path).call, rel_path
          end
        end

        # Symbols for a single repo-relative path, or [] when the path sits in a
        # skipped directory, has no extractor for its language, escapes the repo
        # root, or is unreadable / too large. Used by the incremental re-index
        # (RepoReindexJob), which only touches the files a push changed.
        def symbols_for(rel_path)
          return [] if skipped?(rel_path.to_s)

          # Traversal guard: symbols_for takes a CALLER-SUPPLIED path. The
          # incremental re-index feeds it filenames straight from a GitHub push
          # payload (untrusted). cleanpath resolves any `../`, then we reject
          # anything that escapes @root. each_file_symbols needs no such guard —
          # its paths come from Dir.glob(base: @root) and are already root-bounded.
          abs_path = @root.join(rel_path).cleanpath
          return [] unless abs_path.to_s.start_with?("#{@root}/")

          return [] unless extractor_config(abs_path) && abs_path.file?

          source = read_safely(abs_path)
          return [] if source.nil?

          build_extractor(abs_path, source: source, rel_path: rel_path.to_s).call
        end

        def file_count
          enumerate_files.length
        end

        private

        def enumerate_files
          @enumerate_files ||= Dir.glob('**/*', base: @root.to_s, flags: File::FNM_DOTMATCH)
                                  .lazy
                                  .reject { |p| skipped?(p) }
                                  .map    { |p| @root.join(p) }
                                  .select { |p| source_file?(p) }
                                  .force
        end

        def skipped?(rel_path)
          parts = rel_path.split('/')
          # Skip hidden dirs (.git, .bundle, …) but explicitly NOT "." / ".."
          # segments: those only show up in caller-supplied paths (symbols_for),
          # where the traversal guard — not this hidden-dir rule — must handle them.
          parts.any? { |seg| seg.start_with?('.') && seg != '.' && seg != '..' } ||
            parts.any? { |seg| SKIP_DIRS.include?(seg) }
        end

        def source_file?(abs_path)
          return false unless abs_path.file?

          !extractor_config(abs_path).nil?
        end

        # Registry entry [extractor_class, kwargs] for a path, or nil when its
        # extension is not an indexed language.
        def extractor_config(abs_path)
          EXTENSION_REGISTRY[abs_path.extname]
        end

        # Builds the configured extractor. `**kwargs` carries the per-language
        # config (language tag, grammar) straight from the registry — Ruby gets
        # none, TypeScript gets both — so there's no per-class branching here.
        def build_extractor(abs_path, source:, rel_path:)
          klass, kwargs = extractor_config(abs_path)
          klass.new(source: source, file_path: rel_path, **kwargs)
        end

        def read_safely(path)
          return nil if path.size > MAX_FILE_BYTES

          path.read(encoding: 'utf-8')
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
          nil
        rescue ArgumentError, Encoding::InvalidByteSequenceError
          nil
        end
      end
    end
  end
end

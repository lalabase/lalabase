# frozen_string_literal: true

module Lalabase
  module Indexer
    # Reads project-metadata files and the top-level directory listing of a
    # cloned repository. The output is structured input for VisionGenerator
    # and CapabilityGenerator.
    #
    # Stays small on purpose: only files that help an LLM understand "what is
    # this project". Per-symbol parsing is M6.
    class RepoScanner
      # Files we try in order. First-found wins per category.
      README_FILENAMES = %w[README.md README.rst README.txt README].freeze
      MANIFEST_FILENAMES = %w[Gemfile package.json pyproject.toml Cargo.toml go.mod].freeze
      CLAUDE_FILENAMES = %w[CLAUDE.md].freeze

      MAX_FILE_BYTES = 16_384 # 16 KB per file — LLM context is precious
      MAX_DIR_ENTRIES = 50

      def initialize(repo_root)
        @root = Pathname.new(repo_root)
      end

      # @return [Hash] {readme:, manifests: {Gemfile:..., ...}, claude_md:,
      #                 top_level: [...], language_hint: 'ruby'|...|nil}
      def call
        {
          readme: read_first(README_FILENAMES),
          manifests: read_manifests,
          claude_md: read_first(CLAUDE_FILENAMES),
          top_level: top_level_listing,
          language_hint: detect_language_hint
        }
      end

      private

      def read_first(candidates)
        candidates.each do |name|
          path = @root.join(name)
          return { name: name, content: read_truncated(path) } if path.file?
        end
        nil
      end

      def read_manifests
        MANIFEST_FILENAMES.each_with_object({}) do |name, acc|
          path = @root.join(name)
          acc[name] = read_truncated(path) if path.file?
        end
      end

      def read_truncated(path)
        path.read(MAX_FILE_BYTES, encoding: 'utf-8')
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
        nil
      rescue ArgumentError, Encoding::InvalidByteSequenceError
        # Binary or invalid-encoding file — treat as missing
        nil
      end

      # Returns the top-level directory entries (visible, excluding dotfiles).
      def top_level_listing
        return [] unless @root.directory?

        @root.children
             .reject { |c| c.basename.to_s.start_with?('.') }
             .first(MAX_DIR_ENTRIES)
             .map { |c| c.directory? ? "#{c.basename}/" : c.basename.to_s }
             .sort
      end

      # Heuristic language detection — picks one strong signal.
      def detect_language_hint
        return 'ruby'       if @root.join('Gemfile').file?
        return 'javascript' if @root.join('package.json').file?
        return 'python'     if @root.join('pyproject.toml').file? || @root.join('requirements.txt').file?
        return 'rust'       if @root.join('Cargo.toml').file?
        return 'go'         if @root.join('go.mod').file?

        nil
      end
    end
  end
end

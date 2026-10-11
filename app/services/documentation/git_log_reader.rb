# frozen_string_literal: true

require 'open3'

module Documentation
  # Reads the commit history that touched a set's path_prefix from an already
  # cloned working tree — the v1 source of the documentation logbook (design
  # premise 3c: `git log` already knows author/time/message per change, no own
  # diff-snapshot engine needed).
  #
  # Security: arguments are passed as an array to Open3 (never interpolated
  # into a shell string), so a hostile path_prefix cannot inject commands —
  # the eng-review requirement for every git invocation in this feature.
  class GitLogReader
    class Error < StandardError; end

    # Bounded by the sync job's clone depth — a shallow clone only carries that
    # much history anyway, and the logbook is a recency view, not an archive.
    MAX_COMMITS = 100

    # Machine-readable separators for parsing. %H/%ct cannot contain them; a
    # SUBJECT (%s) can carry any byte except newline, so parsing additionally
    # validates the SHA field — a fragment split off by a separator byte
    # inside a subject fails that check and is dropped (see #parse).
    FIELD_SEPARATOR = "\x1f"
    RECORD_SEPARATOR = "\x1e"
    SHA_FORMAT = /\A\h{40}\z/

    Commit = Struct.new(:sha, :author_name, :committed_at, :message, keyword_init: true)

    # repo_path: Pathname of the cloned working tree.
    # path_prefix: repo-relative docs folder ('.' = repo root).
    def initialize(repo_path:, path_prefix:)
      @repo_path = repo_path
      @path_prefix = path_prefix.presence || '.'
    end

    # Newest first (git log order). Raises Error when git fails — the caller
    # decides whether that is fatal (the sync job treats it as best-effort).
    def commits
      out, status = Open3.capture2(*git_log_args)
      raise Error, "git log failed (exit #{status.exitstatus})" unless status.success?

      parse(out)
    rescue SystemCallError => e
      raise Error, "git log could not run: #{e.message}"
    end

    private

    def git_log_args
      [
        'git', '-C', @repo_path.to_s, 'log',
        "--max-count=#{MAX_COMMITS}",
        # %ct (committer time), not %at: the column is committed_at, and after
        # a rebase the author date can lie arbitrarily far in the past, which
        # would wreck the logbook's recency ordering.
        "--format=%H#{FIELD_SEPARATOR}%an#{FIELD_SEPARATOR}%ct#{FIELD_SEPARATOR}%s#{RECORD_SEPARATOR}",
        '--', @path_prefix
      ]
    end

    def parse(output)
      # Commit metadata is repo-author-controlled and git stores its BYTES
      # verbatim — legacy repos carry non-UTF-8 names/messages. String#split
      # raises ArgumentError on invalid UTF-8, which would escape the sync
      # job's best-effort rescue and fail the sync; scrub instead.
      clean = output.force_encoding(Encoding::UTF_8).scrub

      clean.split(RECORD_SEPARATOR).filter_map do |record|
        sha, author, epoch, subject = record.strip.split(FIELD_SEPARATOR, 4)
        next unless sha&.match?(SHA_FORMAT)

        Commit.new(sha: sha, author_name: author,
                   committed_at: Time.zone.at(epoch.to_i), message: subject.to_s.strip)
      end
    end
  end
end

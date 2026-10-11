# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module Lalabase
  module Indexer
    # Shallow-clones a ProjectRepository into a temporary directory and yields the
    # path. The directory is wiped at the end of the block, even on exception —
    # no source code persists on disk.
    #
    # Security notes:
    #   - Uses Open3.popen3 with separate args (no shell interpolation).
    #   - The PAT is injected as `x-access-token` in the HTTPS URL — GitHub's
    #     recommended scheme. clone_url is private — the token never escapes
    #     this class.
    #   - Strict timeout: on expiry the subprocess is SIGTERM'd, then SIGKILL'd
    #     if it doesn't honour the term. Avoids Ruby's Timeout.timeout pitfall
    #     where a blocked native syscall can leave the subprocess running.
    class GitCloner
      class Error < StandardError; end
      class CloneFailedError < Error; end
      # A clone/fetch that failed specifically because git could not authenticate
      # (expired, revoked or wrong-scope token). Subclass of CloneFailedError so
      # every existing `rescue CloneFailedError` still catches it, while callers
      # that care can show an actionable "update the token" message.
      class AuthenticationError < CloneFailedError; end
      class TimeoutError < Error; end

      # git/GitHub emit one of these when the credentials are bad. Matched against
      # the (already token-redacted) stderr to reclassify the failure.
      AUTH_FAILURE_PATTERN = /
        authentication\ failed |
        invalid\ username\ or\ token |
        could\ not\ read\ username |
        terminal\ prompts\ disabled |
        support\ for\ password\ authentication
      /xi

      DEFAULT_CLONE_TIMEOUT_SECONDS = 90
      DEFAULT_DEPTH = 1
      # ls-remote is a single ref lookup; anything slower than this is a stuck
      # network call, not a big transfer.
      LS_REMOTE_TIMEOUT_SECONDS = 15
      SIGTERM_GRACE_SECONDS = 0.5
      STDERR_CHUNK_SIZE = 8192
      STDERR_JOIN_TIMEOUT_SECONDS = 2

      # The exact commit SHA the cloned working tree points at (HEAD, or the
      # checked-out ref). Set during #call, readable after the block returns —
      # the initial index persists it as last_indexed_commit.
      attr_reader :cloned_commit

      # @param ref [String, nil] when set, check out this exact commit after the
      #   shallow clone. The incremental re-index passes the pushed SHA here so the
      #   indexed working tree matches the commit the diff was computed against —
      #   not just whatever default-branch HEAD happens to be when the job runs
      #   (which can differ under rapid successive pushes). nil = clone HEAD as-is
      #   (the initial-index path).
      def initialize(project_repository, depth: DEFAULT_DEPTH, timeout: DEFAULT_CLONE_TIMEOUT_SECONDS, ref: nil)
        @repository = project_repository
        @depth = depth
        @timeout = timeout
        @ref = ref
      end

      # @yield [Pathname] path to the cloned working tree
      def call(&block)
        raise ArgumentError, 'block required' unless block_given?

        Dir.mktmpdir('lalabase-clone-') do |dir|
          run_clone!(dir)
          @cloned_commit = capture_head_commit(dir)
          block.call(Pathname.new(dir))
        end
      end

      # Tip commit of the remote default branch WITHOUT cloning — one network
      # round-trip. Lets the polling documentation sync skip the full clone
      # when nothing changed. Best-effort BY CONTRACT: any failure (timeout,
      # auth, DNS) returns nil and callers must fall back to the full-clone
      # path — this lookup must never be the reason a sync does not happen.
      def remote_head_commit
        result = nil

        Open3.popen3('git', 'ls-remote', clone_url,
                     "refs/heads/#{@repository.default_branch}") do |stdin, stdout, _stderr, wait_thr|
          stdin.close

          if wait_thr.join(LS_REMOTE_TIMEOUT_SECONDS).nil?
            kill_process_tree!(wait_thr.pid)
            wait_thr.join
          elsif wait_thr.value.success?
            # Output is one "<sha>\t<ref>" line — far below the OS pipe buffer,
            # so reading after process exit cannot deadlock.
            result = stdout.read.split("\t").first.presence
          end
        end

        result
      rescue StandardError => e
        Rails.logger.warn "GitCloner: ls-remote failed — #{redact_token(e.message)}"
        nil
      end

      private

      def clone_url
        # GitHub PAT auth via x-access-token user.
        "https://x-access-token:#{@repository.access_token}@github.com/#{@repository.full_name}.git"
      end

      def run_clone!(dir)
        run_git!(clone_args(dir), action: 'clone')
        return if @ref.nil?

        # Pin the working tree to the exact pushed commit. A shallow single-branch
        # clone only contains the branch tip; if HEAD advanced past @ref between
        # the webhook firing and this job running, the tip != @ref. Fetching the
        # specific commit + checking it out keeps the indexed content consistent
        # with the diff (and with last_indexed_commit). GitHub allows fetching a
        # reachable commit by SHA (allowReachableSHA1InWant).
        run_git!(['git', '-C', dir, 'fetch', '--depth', @depth.to_s, 'origin', @ref], action: 'fetch')
        run_git!(['git', '-C', dir, 'checkout', '--quiet', @ref], action: 'checkout')
      end

      def clone_args(dir)
        ['git', 'clone', '--depth', @depth.to_s,
         '--branch', @repository.default_branch.to_s,
         '--single-branch', clone_url, dir]
      end

      # Runs one git invocation with a hard timeout and a concurrent stderr drain,
      # raising TimeoutError / CloneFailedError on failure. Shared by clone, fetch
      # and checkout so the timeout + token-redaction + kill semantics live in one
      # place. `action` only shapes the error message ("git <action> failed/...").
      def run_git!(args, action:)
        Open3.popen3(*args) do |stdin, _stdout, stderr_io, wait_thr|
          stdin.close

          # Async stderr drain: git can emit far more error output than fits in
          # the OS pipe buffer (~16-64KB on Linux/macOS). Without a concurrent
          # reader, git blocks on the write, wait_thr.join expires, and we
          # raise TimeoutError on what is really a failed-with-long-message.
          # The reader stops on its own at EOF (process exit) or when we kill
          # it after a timeout.
          stderr_buf = +''
          stderr_mutex = Mutex.new
          stderr_thr = start_stderr_reader(stderr_io, stderr_buf, stderr_mutex)

          finished = wait_thr.join(@timeout)
          if finished.nil?
            kill_process_tree!(wait_thr.pid)
            wait_thr.join # ensure thread has truly exited
            stop_stderr_reader!(stderr_thr)
            partial = stderr_mutex.synchronize { stderr_buf.dup }
            sanitized = redact_token(partial).strip
            suffix = sanitized.empty? ? '' : ": #{sanitized}"
            raise TimeoutError, "git #{action} timed out after #{@timeout}s#{suffix}"
          end

          status = wait_thr.value
          stop_stderr_reader!(stderr_thr)
          return if status.success?

          stderr = stderr_mutex.synchronize { stderr_buf.dup }
          sanitized = redact_token(stderr)
          error_class = sanitized.match?(AUTH_FAILURE_PATTERN) ? AuthenticationError : CloneFailedError
          raise error_class, "git #{action} failed (exit #{status.exitstatus}): #{sanitized.strip}"
        end
      end

      def start_stderr_reader(stderr_io, buf, mutex)
        Thread.new do
          while (chunk = stderr_io.read(STDERR_CHUNK_SIZE))
            mutex.synchronize { buf << chunk }
          end
        rescue IOError
          # Pipe closed mid-read (process killed). Whatever was buffered stays.
        end
      end

      def stop_stderr_reader!(thr)
        return unless thr

        # Brief join window in case the reader is mid-syscall after EOF.
        thr.join(STDERR_JOIN_TIMEOUT_SECONDS)
        return unless thr.alive?

        thr.kill
        thr.join
      end

      def kill_process_tree!(pid)
        Process.kill('TERM', pid)
        sleep SIGTERM_GRACE_SECONDS
        begin
          Process.kill('KILL', pid)
        rescue StandardError
          nil
        end
      rescue Errno::ESRCH, Errno::ECHILD
        # Already gone — nothing to do.
      end

      # The exact commit the working tree points at after clone (+ optional ref
      # checkout). Reads stdout (the SHA), so it can't reuse run_git! which only
      # drains stderr. Best-effort: a failure here must never break the index —
      # the run just records a nil commit.
      def capture_head_commit(dir)
        out, status = Open3.capture2('git', '-C', dir, 'rev-parse', 'HEAD')
        status.success? ? out.strip.presence : nil
      rescue StandardError => e
        Rails.logger.warn "GitCloner: could not read HEAD commit — #{e.class}: #{e.message}"
        nil
      end

      # Single source for token redaction (shared with the indexer jobs).
      def redact_token(text)
        Lalabase::Indexer::SecretRedaction.redact(text, @repository.access_token)
      end
    end
  end
end

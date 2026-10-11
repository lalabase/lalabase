# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::GitCloner do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', default_branch: 'main',
                                  access_token: 'ghp_secret_token_value')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # capture_head_commit (inside #call) runs `git rev-parse HEAD` via Open3.capture2.
    # The clone is stubbed (popen3), so the tmpdir is empty — a real rev-parse would
    # only emit "fatal: not a git repository" noise (and spawn a subprocess). Default
    # it to a failed status (→ cloned_commit nil); the #cloned_commit specs override
    # this with a specific `.with(...)` stub.
    allow(Open3).to receive(:capture2).and_return(['', double('Status', success?: false)])
  end
  after { ActsAsTenant.current_tenant = nil }

  # Helpers for stubbing Open3.popen3 — the new implementation uses popen3 with
  # block form (yields stdin, stdout, stderr, wait_thr).
  def stub_popen3(exit_status:, stderr_body: '', timed_out: false)
    wait_thr = double('WaitThread', pid: 12_345)
    # join(timeout) returns nil if the thread exceeded the timeout, otherwise self.
    allow(wait_thr).to receive(:join) { |_tmo| timed_out ? nil : wait_thr }
    allow(wait_thr).to receive(:value).and_return(double('Status', success?: exit_status.zero?,
                                                                   exitstatus: exit_status))
    stdin = StringIO.new
    stdout = StringIO.new('')
    stderr = StringIO.new(stderr_body)
    allow(Open3).to receive(:popen3).and_yield(stdin, stdout, stderr, wait_thr)
    wait_thr
  end

  describe 'error hierarchy' do
    %i[CloneFailedError TimeoutError].each do |sym|
      it "#{sym} descends from Error (single rescue catches it)" do
        expect(described_class.const_get(sym).ancestors).to include(described_class::Error)
      end
    end
  end

  describe '#clone_url is PRIVATE (token containment)' do
    # Catches mutation: someone re-exposes the URL builder, accidentally leaking
    # the token to callers (or to inspect/log).
    it 'is not in the public method list' do
      expect(described_class.new(repository).public_methods).not_to include(:clone_url)
    end
  end

  describe '#call' do
    it 'requires a block' do
      expect { described_class.new(repository).call }.to raise_error(ArgumentError, /block/)
    end

    it 'yields a Pathname to a freshly-created directory and cleans up afterwards' do
      stub_popen3(exit_status: 0)
      yielded_path = nil
      described_class.new(repository).call { |path| yielded_path = path }
      expect(yielded_path).to be_a(Pathname)
      expect(yielded_path).not_to exist
    end

    it 'invokes git via popen3 with --depth 1 --branch <default_branch> --single-branch' do
      stub_popen3(exit_status: 0)
      described_class.new(repository).call { |_| }
      expect(Open3).to have_received(:popen3).with(
        'git', 'clone', '--depth', '1', '--branch', 'main', '--single-branch',
        'https://x-access-token:ghp_secret_token_value@github.com/acme/backend.git',
        a_string_matching(%r{/lalabase-clone-})
      )
    end

    it 'respects a custom depth' do
      stub_popen3(exit_status: 0)
      described_class.new(repository, depth: 5).call { |_| }
      expect(Open3).to have_received(:popen3).with(
        'git', 'clone', '--depth', '5', anything, anything, anything, anything, anything
      )
    end

    it 'cleans up the directory even when the block raises' do
      stub_popen3(exit_status: 0)
      yielded_path = nil
      expect do
        described_class.new(repository).call do |path|
          yielded_path = path
          raise 'caller-bug'
        end
      end.to raise_error('caller-bug')
      expect(yielded_path).not_to exist
    end

    context 'when git clone fails (non-zero exit)' do
      it 'raises CloneFailedError with the git stderr' do
        stub_popen3(exit_status: 128, stderr_body: 'fatal: repository not found')
        expect do
          described_class.new(repository).call { |_| }
        end.to raise_error(described_class::CloneFailedError, /git clone failed.*repository not found/)
      end

      it 'redacts the access token from the error message (no token in logs)' do
        stub_popen3(exit_status: 128, stderr_body: 'fatal: error using ghp_secret_token_value')
        expect do
          described_class.new(repository).call { |_| }
        end.to raise_error(described_class::CloneFailedError, /\[REDACTED\]/)
      end

      it 'redacts EVERY occurrence of the token (catches gsub→sub mutation)' do
        leaky = 'ghp_secret_token_value A ghp_secret_token_value B ghp_secret_token_value'
        stub_popen3(exit_status: 128, stderr_body: leaky)
        expect do
          described_class.new(repository).call { |_| }
        end.to raise_error(described_class::CloneFailedError) do |e|
          expect(e.message).not_to include('ghp_secret_token_value')
          expect(e.message.scan('[REDACTED]').size).to eq(3)
        end
      end
    end

    # An expired/revoked/wrong-scope token makes git fail with a recognisable auth
    # message. We reclassify it so callers can show "update your token" instead of a
    # raw exit code — while keeping it a CloneFailedError so existing rescues hold.
    context 'when the failure is an authentication error' do
      it 'AuthenticationError descends from CloneFailedError (existing rescues still catch it)' do
        expect(described_class::AuthenticationError.ancestors).to include(described_class::CloneFailedError)
      end

      # The exact GitHub stderr the user hit.
      it 'raises AuthenticationError for "Invalid username or token / Authentication failed"' do
        stub_popen3(exit_status: 128,
                    stderr_body: "remote: Invalid username or token. Password authentication is not supported.\n" \
                                 "fatal: Authentication failed for 'https://github.com/acme/backend.git/'")
        expect { described_class.new(repository).call { |_| } }
          .to raise_error(described_class::AuthenticationError)
      end

      it 'raises AuthenticationError on a fetch/checkout auth failure too (ref: path)' do
        # clone ok, fetch fails with auth → still classified as auth.
        call_count = 0
        allow(Open3).to receive(:popen3) do |*_args, &blk|
          call_count += 1
          exit_status = call_count >= 2 ? 128 : 0
          wait_thr = double('WaitThread', pid: 1)
          allow(wait_thr).to receive(:join).and_return(wait_thr)
          allow(wait_thr).to receive(:value).and_return(double(success?: exit_status.zero?, exitstatus: exit_status))
          blk.call(StringIO.new, StringIO.new(''), StringIO.new('fatal: Authentication failed'), wait_thr)
        end
        expect { described_class.new(repository, ref: 'deadbeef').call { |_| } }
          .to raise_error(described_class::AuthenticationError, /git fetch failed/)
      end

      # A non-auth failure must NOT be swept into AuthenticationError (would mislead
      # the user to "update your token" when the repo is simply gone).
      it 'keeps a non-auth failure (e.g. repository not found) as a plain CloneFailedError' do
        stub_popen3(exit_status: 128, stderr_body: 'fatal: repository not found')
        expect { described_class.new(repository).call { |_| } }
          .to raise_error(described_class::CloneFailedError) { |e| expect(e).not_to be_a(described_class::AuthenticationError) }
      end
    end

    context 'with a stderr body larger than the OS pipe buffer (deadlock regression)' do
      # Strict-review audit: macOS/Linux pipe buffers are ~16-64KB. If git
      # emits more stderr than fits, the child blocks on write while
      # wait_thr.join sits idle → we'd see a TimeoutError on what is really
      # an auth/network failure with a long message. Async drainer fixes it.
      #
      # Uses a real subprocess (sh + yes + head) so we exercise the actual
      # pipe-buffer semantics. The cloner's `args` would point to git; we
      # substitute via and_wrap_original so the spawned process is harmless.
      it 'captures the full stderr without spuriously timing out' do
        big_cmd = ['sh', '-c', 'yes x | head -c 500000 >&2; exit 1']
        allow(Open3).to receive(:popen3).and_wrap_original do |original, *_args, &block|
          original.call(*big_cmd, &block)
        end

        err = nil
        begin
          described_class.new(repository, timeout: 5).call { |_| }
        rescue described_class::CloneFailedError, described_class::TimeoutError => e
          err = e
        end

        expect(err).to be_a(described_class::CloneFailedError),
                       "expected CloneFailedError, got #{err.class}: #{err.message[0, 200]}..."
        # 500KB written. Sanitisation/strip might trim a bit, but we should
        # see comfortably more than any single pipe buffer.
        expect(err.message.length).to be > 100_000
      end
    end

    context 'when git clone exceeds the timeout' do
      # The new implementation uses wait_thr.join(timeout) which returns nil on
      # timeout, then we send SIGTERM + SIGKILL. This is reliable (unlike
      # Timeout.timeout, which can leave the subprocess running).
      it 'raises TimeoutError and signals the subprocess (TERM then KILL)' do
        stub_popen3(exit_status: 0, timed_out: true)
        expect(Process).to receive(:kill).with('TERM', 12_345).ordered
        expect(Process).to receive(:kill).with('KILL', 12_345).ordered
        expect { described_class.new(repository, timeout: 0.05).call { |_| } }
          .to raise_error(described_class::TimeoutError, /timed out after/)
      end

      it 'tolerates Errno::ESRCH on kill (subprocess already exited)' do
        stub_popen3(exit_status: 0, timed_out: true)
        allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
        expect { described_class.new(repository, timeout: 0.05).call { |_| } }
          .to raise_error(described_class::TimeoutError)
      end

      it 'TimeoutError descends from Error (rescue-class hierarchy)' do
        expect(described_class::TimeoutError.ancestors).to include(described_class::Error)
      end
    end
  end

  describe '#cloned_commit (the last_indexed_commit fix)' do
    # This is the actual mechanism behind the M9 fix — the job specs stub it, so
    # without these the fix is unverified. capture_head_commit runs `git rev-parse
    # HEAD` via Open3.capture2 (reads stdout, unlike the clone's popen3).
    it 'exposes the cloned HEAD commit, newline-trimmed' do
      stub_popen3(exit_status: 0) # clone succeeds
      allow(Open3).to receive(:capture2)
        .with('git', '-C', anything, 'rev-parse', 'HEAD')
        .and_return(["abc123def\n", double('Status', success?: true)])

      cloner = described_class.new(repository)
      cloner.call { |_| }
      expect(cloner.cloned_commit).to eq('abc123def') # .strip removed the trailing newline
    end

    it 'leaves cloned_commit nil when rev-parse fails — best-effort, must NOT break the clone' do
      stub_popen3(exit_status: 0)
      allow(Open3).to receive(:capture2)
        .with('git', '-C', anything, 'rev-parse', 'HEAD')
        .and_return(['', double('Status', success?: false)])

      cloner = described_class.new(repository)
      expect { cloner.call { |_| } }.not_to raise_error
      expect(cloner.cloned_commit).to be_nil
    end

    it 'leaves cloned_commit nil when rev-parse RAISES — the rescue must not break the clone' do
      stub_popen3(exit_status: 0)
      allow(Open3).to receive(:capture2)
        .with('git', '-C', anything, 'rev-parse', 'HEAD')
        .and_raise(Errno::ENOENT, 'git not found')

      cloner = described_class.new(repository)
      expect { cloner.call { |_| } }.not_to raise_error # catches removal of the rescue
      expect(cloner.cloned_commit).to be_nil
    end

    it 'treats whitespace-only rev-parse output as nil (.strip.presence, not "")' do
      stub_popen3(exit_status: 0)
      allow(Open3).to receive(:capture2)
        .with('git', '-C', anything, 'rev-parse', 'HEAD')
        .and_return(["   \n", double('Status', success?: true)])

      cloner = described_class.new(repository)
      cloner.call { |_| }
      expect(cloner.cloned_commit).to be_nil # catches `.strip.presence` → `.strip` (would be "")
    end
  end

  describe 'ref: checkout the exact pushed commit (incremental re-index)' do
    # All git invocations succeed; we just assert the fetch + checkout happen.
    def stub_all_git_success
      allow(Open3).to receive(:popen3) do |*_args, &blk|
        wait_thr = double('WaitThread', pid: 1)
        allow(wait_thr).to receive(:join).and_return(wait_thr)
        allow(wait_thr).to receive(:value).and_return(double(success?: true, exitstatus: 0))
        blk.call(StringIO.new, StringIO.new(''), StringIO.new(''), wait_thr)
      end
    end

    it 'fetches and checks out the ref after the shallow clone' do
      stub_all_git_success
      described_class.new(repository, ref: 'deadbeef123').call { |_| }

      expect(Open3).to have_received(:popen3).with(
        'git', 'clone', '--depth', '1', '--branch', 'main', '--single-branch', anything, anything
      )
      expect(Open3).to have_received(:popen3).with('git', '-C', anything, 'fetch', '--depth', '1', 'origin', 'deadbeef123')
      expect(Open3).to have_received(:popen3).with('git', '-C', anything, 'checkout', '--quiet', 'deadbeef123')
    end

    it 'does NOT fetch/checkout when no ref is given (initial-index path unchanged)' do
      stub_all_git_success
      described_class.new(repository).call { |_| }
      expect(Open3).not_to have_received(:popen3).with('git', '-C', anything, 'checkout', anything, anything)
    end

    it 'surfaces a failed checkout as CloneFailedError with the action in the message' do
      call_count = 0
      allow(Open3).to receive(:popen3) do |*_args, &blk|
        call_count += 1
        exit_status = call_count >= 3 ? 1 : 0 # clone + fetch ok, checkout fails
        wait_thr = double('WaitThread', pid: 1)
        allow(wait_thr).to receive(:join).and_return(wait_thr)
        allow(wait_thr).to receive(:value).and_return(double(success?: exit_status.zero?, exitstatus: exit_status))
        blk.call(StringIO.new, StringIO.new(''), StringIO.new('fatal: reference is not a tree'), wait_thr)
      end
      expect { described_class.new(repository, ref: 'badsha').call { |_| } }
        .to raise_error(described_class::CloneFailedError, /git checkout failed/)
    end
  end

  describe 'constants locked as contract' do
    it { expect(described_class::DEFAULT_DEPTH).to eq(1) }
    it { expect(described_class::DEFAULT_CLONE_TIMEOUT_SECONDS).to eq(90) }
    it { expect(described_class::SIGTERM_GRACE_SECONDS).to eq(0.5) }
    it { expect(described_class::STDERR_CHUNK_SIZE).to eq(8192) }
    it { expect(described_class::STDERR_JOIN_TIMEOUT_SECONDS).to eq(2) }

    it 'tmpdir prefix is "lalabase-clone-" (incident-response grep target)' do
      stub_popen3(exit_status: 0)
      captured = nil
      allow(Open3).to receive(:popen3) do |*args, &blk|
        captured = args.last
        wait_thr = double(pid: 1, join: double, value: double(success?: true, exitstatus: 0))
        allow(wait_thr).to receive(:join).and_return(wait_thr)
        blk.call(StringIO.new, StringIO.new(''), StringIO.new(''), wait_thr)
      end
      described_class.new(repository).call { |_| }
      expect(File.basename(captured)).to start_with('lalabase-clone-')
    end
  end

  describe 'branch name handled as a separate Open3 argument (no shell escape)' do
    it 'passes a branch name containing a slash through unchanged' do
      ActsAsTenant.with_tenant(organisation) do
        feature_repo = create(:project_repository, project: project, organisation: organisation,
                                                   full_name: 'acme/x', default_branch: 'feature/foo',
                                                   access_token: 't')
        stub_popen3(exit_status: 0)
        described_class.new(feature_repo).call { |_| }
        expect(Open3).to have_received(:popen3).with(
          'git', 'clone', '--depth', '1', '--branch', 'feature/foo', '--single-branch', anything, anything
        )
      end
    end
  end

  describe 'access_token nil defensive path' do
    it 'redaction does not crash when access_token is nil' do
      repo_with_nil = repository
      repo_with_nil.access_token = nil
      stub_popen3(exit_status: 1, stderr_body: 'fatal: oops')
      expect { described_class.new(repo_with_nil).call { |_| } }
        .to raise_error(described_class::CloneFailedError)
    end
  end

  describe '#remote_head_commit' do
    # Real `git ls-remote` against a local throwaway repo — ls-remote accepts
    # filesystem paths, so only clone_url needs stubbing. The timeout/kill
    # mechanics are the same popen3+join pattern the clone specs above cover.
    def build_local_repo
      dir = Dir.mktmpdir('cloner-lsremote-')
      (@local_repos ||= []) << dir
      system('git', 'init', '-b', 'main', dir, out: File::NULL, err: File::NULL)
      system('git', '-C', dir, 'config', 'user.email', 'spec@example.com', out: File::NULL)
      system('git', '-C', dir, 'config', 'user.name', 'Spec', out: File::NULL)
      File.write(File.join(dir, 'a.txt'), 'x')
      system('git', '-C', dir, 'add', '.', out: File::NULL)
      system('git', '-C', dir, 'commit', '-m', 'init', out: File::NULL, err: File::NULL)
      dir
    end

    after { @local_repos&.each { |d| FileUtils.remove_entry(d, true) } }

    it 'returns the tip commit of the default branch' do
      dir = build_local_repo
      cloner = described_class.new(repository) # default_branch 'main' matches init -b
      allow(cloner).to receive(:clone_url).and_return(dir)
      # Backticks, not Open3.capture2 — capture2 is stubbed globally above.
      expected_sha = `git -C #{dir} rev-parse HEAD`.strip

      expect(cloner.remote_head_commit).to eq(expected_sha)
    end

    it 'returns nil for an unreachable remote (never raises — callers fail open)' do
      cloner = described_class.new(repository)
      allow(cloner).to receive(:clone_url).and_return('/nonexistent/nowhere.git')

      expect(cloner.remote_head_commit).to be_nil
    end
  end
end

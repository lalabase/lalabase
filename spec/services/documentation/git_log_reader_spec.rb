# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::GitLogReader — commit history filtered to a docs folder.
# Type: Service spec (against a REAL throwaway git repo, so the actual git
#       invocation and parsing are exercised, not a stub of ourselves).
# Why:  The logbook must show exactly the commits that touched the docs folder,
#       newest first, and fail loudly (typed error) when git cannot run.
RSpec.describe Documentation::GitLogReader do
  around do |example|
    Dir.mktmpdir('git-log-reader-spec-') do |dir|
      @repo = Pathname.new(dir)
      example.run
    end
  end

  def git(*args)
    system('git', '-C', @repo.to_s, *args, out: File::NULL, err: File::NULL) || raise("git #{args.first} failed")
  end

  def commit_file(path, message:)
    full = @repo.join(path)
    FileUtils.mkdir_p(full.dirname)
    # binwrite: messages in these specs may carry non-UTF-8/control bytes.
    File.binwrite(full, "content for #{path}")
    git('add', '.')
    git('commit', '-m', message)
  end

  def build_repo
    git('init', '--quiet')
    git('config', 'user.email', 'spec@example.com')
    git('config', 'user.name', 'Spec Runner')
    commit_file('docs/intro.md', message: 'docs: add intro')
    commit_file('README.md', message: 'chore: readme only')
    commit_file('docs/guide/setup.md', message: 'docs: add setup')
  end

  it 'returns only commits touching the path_prefix, newest first' do
    build_repo

    commits = described_class.new(repo_path: @repo, path_prefix: 'docs/').commits

    expect(commits.map(&:message)).to eq(['docs: add setup', 'docs: add intro'])
    expect(commits.first.author_name).to eq('Spec Runner')
    expect(commits.first.sha).to match(/\A[0-9a-f]{40}\z/)
    expect(commits.first.committed_at).to be_within(1.minute).of(Time.current)
  end

  it 'includes every commit when the prefix is the repo root (".")' do
    build_repo

    commits = described_class.new(repo_path: @repo, path_prefix: '.').commits

    expect(commits.size).to eq(3)
  end

  it 'treats a blank prefix as the repo root instead of producing an invalid pathspec' do
    build_repo

    expect(described_class.new(repo_path: @repo, path_prefix: '').commits.size).to eq(3)
  end

  it 'returns an empty list when no commit touched the prefix' do
    build_repo

    expect(described_class.new(repo_path: @repo, path_prefix: 'elsewhere/').commits).to eq([])
  end

  it 'raises a typed error when the directory is not a git repository' do
    # No build_repo — the tmpdir is a plain directory.
    expect do
      described_class.new(repo_path: @repo, path_prefix: 'docs/').commits
    end.to raise_error(described_class::Error, /git log/)
  end

  # Commit metadata is repo-author-controlled: git stores message/name BYTES
  # verbatim, so legacy repos can carry non-UTF-8 — parsing must scrub, not
  # crash (an ArgumentError here would escape the sync job's best-effort
  # rescue and fail an otherwise successful sync).
  it 'survives a commit message that is not valid UTF-8' do
    build_repo
    commit_file('docs/legacy.md', message: "latin1 umlaut: \xE4".dup.force_encoding('ASCII-8BIT'))

    commits = described_class.new(repo_path: @repo, path_prefix: 'docs/').commits

    expect(commits.first.message).to include('latin1 umlaut')
  end

  # A subject may contain our record separator byte; the fragment split off
  # behind it has no valid SHA and must be dropped, not surface as a bogus
  # logbook row.
  it 'drops garbage records split off by a separator byte inside a subject' do
    build_repo
    commit_file('docs/tricky.md', message: "legit#{described_class::RECORD_SEPARATOR}injected-tail")

    commits = described_class.new(repo_path: @repo, path_prefix: 'docs/').commits

    expect(commits.size).to eq(3) # tricky + setup + intro, nothing injected
    expect(commits.first.message).to eq('legit')
    expect(commits.map(&:sha)).to all(match(/\A\h{40}\z/))
  end
end

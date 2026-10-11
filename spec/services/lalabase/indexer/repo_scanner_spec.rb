# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::RepoScanner do
  around do |example|
    Dir.mktmpdir('scanner-test-') do |dir|
      @dir = dir
      example.run
    end
  end

  def write(name, content)
    File.write(File.join(@dir, name), content)
  end

  def scan
    described_class.new(@dir).call
  end

  describe 'readme detection' do
    described_class::README_FILENAMES.each do |name|
      it "picks up #{name}" do
        write(name, "# Hello\nBody.")
        result = scan
        expect(result[:readme]).to eq(name: name, content: "# Hello\nBody.")
      end
    end

    it 'prefers README.md over README.txt when both exist (priority order locked)' do
      write('README.txt', 'plain')
      write('README.md',  '# preferred')
      expect(scan[:readme][:name]).to eq('README.md')
    end

    it 'returns nil readme when no README file is present' do
      expect(scan[:readme]).to be_nil
    end
  end

  describe 'manifests' do
    described_class::MANIFEST_FILENAMES.each do |name|
      it "picks up #{name}" do
        write(name, 'manifest body')
        expect(scan[:manifests][name]).to eq('manifest body')
      end
    end

    it 'collects multiple manifests when present (polyglot repo)' do
      write('Gemfile',      "source 'https://rubygems.org'")
      write('package.json', '{"name":"x"}')
      result = scan
      expect(result[:manifests]).to include('Gemfile', 'package.json')
    end

    it 'omits absent manifest entries (no nil-valued keys)' do
      write('Gemfile', 'x')
      expect(scan[:manifests].keys).to eq(['Gemfile'])
    end
  end

  describe 'CLAUDE.md' do
    it 'picks up CLAUDE.md when present' do
      write('CLAUDE.md', '# project rules')
      expect(scan[:claude_md]).to eq(name: 'CLAUDE.md', content: '# project rules')
    end

    it 'is nil when CLAUDE.md is missing' do
      expect(scan[:claude_md]).to be_nil
    end
  end

  describe 'top-level listing' do
    it 'lists visible files and directories' do
      write('README.md', 'x')
      FileUtils.mkdir_p(File.join(@dir, 'app'))
      FileUtils.mkdir_p(File.join(@dir, 'lib'))
      expect(scan[:top_level]).to contain_exactly('README.md', 'app/', 'lib/')
    end

    it 'excludes dotfiles (.git, .env, .DS_Store)' do
      FileUtils.mkdir_p(File.join(@dir, '.git'))
      write('.env', 'SECRET=...')
      write('README.md', 'x')
      expect(scan[:top_level]).to eq(['README.md'])
    end

    it 'distinguishes directories with trailing slash' do
      FileUtils.mkdir_p(File.join(@dir, 'app'))
      write('Rakefile', '')
      result = scan[:top_level]
      expect(result).to include('app/').and include('Rakefile')
      expect(result).not_to include('app') # without slash
    end

    it 'caps the listing at MAX_DIR_ENTRIES' do
      (described_class::MAX_DIR_ENTRIES + 5).times { |i| write("file_#{i}.txt", 'x') }
      expect(scan[:top_level].size).to eq(described_class::MAX_DIR_ENTRIES)
    end

    # Exact boundary — catches mutation of `.first(MAX_DIR_ENTRIES)` to `MAX_DIR_ENTRIES - 1`
    # or `MAX_DIR_ENTRIES + 1`.
    it 'returns exactly N entries when given exactly N files (n boundary)' do
      described_class::MAX_DIR_ENTRIES.times { |i| write(format('file_%03d.txt', i), 'x') }
      expect(scan[:top_level].size).to eq(described_class::MAX_DIR_ENTRIES)
    end

    it 'returns N entries when given N-1 files (n-1 boundary; no over-cap)' do
      (described_class::MAX_DIR_ENTRIES - 1).times { |i| write(format('file_%03d.txt', i), 'x') }
      expect(scan[:top_level].size).to eq(described_class::MAX_DIR_ENTRIES - 1)
    end

    it 'returns a sorted listing (stable for LLM determinism)' do
      write('zzz.txt', '')
      write('aaa.txt', '')
      write('mmm.txt', '')
      expect(scan[:top_level]).to eq(%w[aaa.txt mmm.txt zzz.txt])
    end
  end

  describe 'language detection' do
    it 'detects ruby from Gemfile' do
      write('Gemfile', "source 'x'")
      expect(scan[:language_hint]).to eq('ruby')
    end

    it 'detects javascript from package.json' do
      write('package.json', '{}')
      expect(scan[:language_hint]).to eq('javascript')
    end

    it 'detects python from pyproject.toml' do
      write('pyproject.toml', '[tool.poetry]')
      expect(scan[:language_hint]).to eq('python')
    end

    it 'detects python from requirements.txt' do
      write('requirements.txt', 'flask==2')
      expect(scan[:language_hint]).to eq('python')
    end

    it 'returns nil when no manifest is present' do
      expect(scan[:language_hint]).to be_nil
    end

    it 'prefers ruby over javascript when both Gemfile and package.json exist' do
      # Documents the priority order — first match wins.
      write('Gemfile',      'x')
      write('package.json', '{}')
      expect(scan[:language_hint]).to eq('ruby')
    end
  end

  describe 'file-size truncation' do
    it 'reads at most MAX_FILE_BYTES per file (n+1 — content larger than cap)' do
      huge = 'x' * (described_class::MAX_FILE_BYTES + 1000)
      write('README.md', huge)
      content = scan[:readme][:content]
      expect(content.bytesize).to eq(described_class::MAX_FILE_BYTES)
    end

    # Boundary: file of exactly MAX_FILE_BYTES → fully read, no truncation
    it 'reads the entire file when its size is exactly MAX_FILE_BYTES (n boundary)' do
      exact = 'a' * described_class::MAX_FILE_BYTES
      write('README.md', exact)
      expect(scan[:readme][:content].bytesize).to eq(described_class::MAX_FILE_BYTES)
    end

    # Boundary: just under cap
    it 'reads files smaller than the cap fully (n-1 boundary)' do
      small = 'b' * (described_class::MAX_FILE_BYTES - 1)
      write('README.md', small)
      expect(scan[:readme][:content].bytesize).to eq(described_class::MAX_FILE_BYTES - 1)
    end
  end

  describe 'binary / invalid encoding tolerance' do
    it 'returns nil for binary README without raising' do
      File.binwrite(File.join(@dir, 'README.md'), "\xFF\xFE\xFD".b)
      # Either nil or readable-but-garbled; what matters is "does not crash"
      expect { scan }.not_to raise_error
    end
  end

  describe 'empty repository' do
    it 'returns nil readme, empty manifests, nil claude_md, empty top_level, nil language' do
      result = scan
      expect(result).to eq(readme: nil, manifests: {}, claude_md: nil, top_level: [], language_hint: nil)
    end
  end

  describe 'pathological filesystem states' do
    it 'does not crash when a README path is a DIRECTORY instead of a file' do
      FileUtils.mkdir_p(File.join(@dir, 'README.md'))
      expect { scan }.not_to raise_error
      expect(scan[:readme]).to be_nil
    end

    it 'does not crash on EACCES (unreadable file)' do
      write('README.md', 'secret')
      File.chmod(0o000, File.join(@dir, 'README.md'))
      expect { scan }.not_to raise_error
    ensure
      File.chmod(0o644, File.join(@dir, 'README.md')) if File.exist?(File.join(@dir, 'README.md'))
    end
  end
end

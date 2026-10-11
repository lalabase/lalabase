# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/lalabase/leak_guard'

# What: Lalabase::LeakGuard, which script/leak_guard runs on every pull request
#       (.github/workflows/leaks.yml) with the real key and digests.
# Why:  Once the repository is public, every merged commit is public at once.
#       These tests use a key and words of their own: the real ones are a CI
#       secret and a private list, and must not appear here either.
RSpec.describe Lalabase::LeakGuard, :ci_guard do
  let(:key) { 'test-key-not-the-real-one' }
  let(:secret_words) { %w[prod.secret.example u123456 private@mail.example 203.0.113.77 oldname] }
  let(:digests) { secret_words.map { |word| described_class.digest(key, word) } }

  def findings(files) = described_class.findings(files, key: key, digests: digests)

  describe '.tokens' do
    it 'yields addresses, dotted names and every word inside them' do
      tokens = described_class.tokens('ssh u123456-sub1@u123456.box.example then prod.secret.example:22')

      expect(tokens).to include('u123456-sub1@u123456.box.example', 'u123456.box.example', 'u123456',
                                'prod.secret.example', 'secret')
    end

    it 'yields the host inside an address and inside a longer dotted name' do
      expect(described_class.tokens('ssh deploy@prod.secret.example')).to include('prod.secret.example')
      expect(described_class.tokens('https://www.prod.secret.example.com/x')).to include('prod.secret.example')
    end

    it 'is case-insensitive' do
      expect(described_class.tokens('OldName')).to include('oldname')
    end

    # Review of #969, point 4: the ways we actually write these words.
    it 'yields a host glued to a German compound, an address glued to a flag, a name inside CamelCase' do
      expect(described_class.tokens('Der prod.secret.example-Server')).to include('prod.secret.example')
      expect(described_class.tokens('ssh old-prod.secret.example')).to include('prod.secret.example')
      expect(described_class.tokens('mysql -h203.0.113.77')).to include('203.0.113.77')
      expect(described_class.tokens('class OldNameService')).to include('oldname')
    end

    it 'yields a host written as a pattern or URL-encoded, and an IPv4 address in reverse DNS' do
      expect(described_class.tokens('/prod\\.secret\\.example/')).to include('prod.secret.example')
      expect(described_class.tokens('mailto:private%40mail.example')).to include('private@mail.example')
      # Private on purpose in both orders: the reversed form of a documentation
      # address looks like a real public one, and the export check refuses it.
      expect(described_class.tokens('10.30.20.10.in-addr.arpa')).to include('10.20.30.10')
    end
  end

  # Review 2 of #969, question 4: how these words get written by accident.
  describe '.tokens, spellings' do
    it 'yields a word written with _ or - as the plain word, and a word with an umlaut' do
      expect(described_class.tokens('OLD_NAME and old-name')).to include('oldname')
      expect(described_class.tokens('Wiese kühweide')).to include('kühweide')
    end

    it 'yields an IPv4 address with leading zeros or dashes, and an address without its +tag' do
      expect(described_class.tokens('203.000.113.077')).to include('203.0.113.77')
      expect(described_class.tokens('ip-203-0-113-77.eu')).to include('203.0.113.77')
      expect(described_class.tokens('private+lb@mail.example')).to include('private@mail.example')
    end
  end

  # Review 2 of #969, finding 6: a NUL byte or UTF-16 hid a text from every check.
  describe '.readable' do
    it 'reads a text behind a NUL byte and a UTF-16 text' do
      expect(described_class.readable("\x00host prod.secret.example\n")).to include('prod.secret.example')
      expect(described_class.readable("\xFF\xFE".b + "host u123456\n".encode('UTF-16LE').b)).to include('u123456')
    end
  end

  # Review 2 of #969, findings 4 and 5: names are read without parsing a diff.
  describe '.raw_entries' do
    it 'reads status, mode and path from git diff-tree -z --raw, a rename by its new path' do
      out = ":000000 120000 #{'0' * 40} #{'a' * 40} A\0link\0" \
            ":100644 100644 #{'b' * 40} #{'b' * 40} R100\0a\0my dir/ä.md\0" \
            ":100644 000000 #{'c' * 40} #{'0' * 40} D\0gone\0"

      expect(described_class.raw_entries(out)).to eq([%w[A 120000 link], ['R', '100644', 'my dir/ä.md'], %w[D 000000 gone]])
    end
  end

  # The generator in the private repository refuses a word this would never yield.
  describe '.matchable?' do
    it 'is true for a word the tokenizer yields as it is, false for one with / or :' do
      expect(%w[prod.secret.example u123456 private@mail.example 203.0.113.77 old_name kühweide].all? { |w| described_class.matchable?(w) })
        .to be(true)
      expect(['/srv/app', 'host:22', 'two words'].none? { |w| described_class.matchable?(w) }).to be(true)
    end
  end

  # Review of #969, point 1: a wrong key found nothing and said so in green.
  describe '.key_matches?' do
    let(:text) { "# comment\nkey-check #{described_class.key_check(key)}\n#{digests.join("\n")}\n" }

    it 'holds for the key the digests were made with, and for no other' do
      expect(described_class.key_matches?(key, text)).to be(true)
      expect(described_class.key_matches?('wrong-key', text)).to be(false)
      expect(described_class.key_matches?(key, digests.join("\n"))).to be(false)
    end
  end

  describe '.env_value' do
    it 'reads a value from an env file, bare, quoted or exported' do
      expect(described_class.env_value("A=1\nLEAK_GUARD_KEY=abc\n", 'LEAK_GUARD_KEY')).to eq('abc')
      expect(described_class.env_value(%(LEAK_GUARD_KEY="abc"\n), 'LEAK_GUARD_KEY')).to eq('abc')
      expect(described_class.env_value("export LEAK_GUARD_KEY='abc'\n", 'LEAK_GUARD_KEY')).to eq('abc')
      expect(described_class.env_value("OTHER=1\n", 'LEAK_GUARD_KEY')).to be_nil
    end
  end

  # Review of #969, point 3: what a commit adds and says, not only the end state.
  describe '.history_records' do
    let(:marker) { 'leak-guard-1a2b3c' }
    let(:log) do
      "#{marker} #{'abc1234567' * 4}\n#{marker}-who A <a@example.com> / u123456 <c@example.com>\nfix: talk about prod.secret.example\nleak-guard-end-of-message\nssh u123456\nleak-guard-ffff #{'1' * 40}\n\n#{marker}-end\n\n" \
        "diff --git a/c.rb b/c.rb\n--- a/c.rb\n+++ b/c.rb\n@@ -1 +1 @@\n-old line prod.secret.example\n+new line\n" \
        "#{marker} #{'def4567890' * 4}\nmerge\n\n#{marker}-end\n\n" \
        "diff --git a/my dir/d.yml b/my dir/d.yml\nnew file mode 100644\n--- /dev/null\n+++ b/my dir/d.yml\t\n@@ -0,0 +1,2 @@\n+a: 1\n+host: u123456\n" \
        "diff --git a/q b/q\n--- a/q\n+++ \"b/q\\\"x.rb\"\n@@ -0,0 +1 @@\n+x\n"
    end

    it 'yields each commit: its message (a marker of another run does not end it) and the lines it added' do
      records = described_class.history_records(log.lines, marker: marker).to_a

      expect(records).to eq([
                              { 'abc1234567 (identity)' => "A <a@example.com> / u123456 <c@example.com>\n",
                                'abc1234567 (message)' => "fix: talk about prod.secret.example\nleak-guard-end-of-message\n" \
                                                          "ssh u123456\nleak-guard-ffff #{'1' * 40}\n",
                                'abc1234567 c.rb (added)' => "new line\n" },
                              { 'def4567890 (message)' => "merge\n",
                                'def4567890 my dir/d.yml (added)' => "a: 1\nhost: u123456\n",
                                'def4567890 q\\"x.rb (added)' => "x\n" }
                            ])
      expect(findings(records.reduce(:merge))).to contain_exactly('abc1234567 (identity):1',
                                                                  'abc1234567 (message):1', 'abc1234567 (message):3',
                                                                  'def4567890 my dir/d.yml (added):2')
    end
  end

  # Review of #969, point 12.
  describe '.gitleaks_config_problems' do
    it 'refuses exceptions by path or commit, upstream defaults, and a global allowlist that is not exact values' do
      config = <<~TOML
        [extend]
        useDefault = true
        [[rules.allowlists]]
        paths = ['''x''']
        commits = ["abc"]
        [[allowlists]]
        regexTarget = "secret"
        stopwords = ["test"]
        regexes = [
          '''^sk-test-123$''',
          '''^sk-.*$''',
        ]
      TOML

      expect(described_class.gitleaks_config_problems(config))
        .to contain_exactly('[extend] (pulls in the upstream exceptions)', 'paths =', 'commits =',
                            'stopwords in a global allowlist',
                            "a global allowlist value that is not exact: '''^sk-.*$'''")
    end

    it 'finds nothing in the config of this repository' do
      expect(described_class.gitleaks_config_problems(File.read(File.expand_path('../../../.gitleaks.toml', __dir__))))
        .to eq([])
    end
  end

  describe '.findings' do
    it 'finds a listed word in a line, inside an address, in a path and as an IPv4 address' do
      files = {
        'config/a.yml' => "host: prod.secret.example\n",
        'ops/b.sh' => "REMOTE=u123456-sub2@u123456.your-box.example\n",
        'docs/oldname_notes.md' => "nothing here\n",
        'c.rb' => "SERVER = '203.0.113.77'\n# the private@mail.example login\n"
      }

      expect(findings(files)).to contain_exactly('config/a.yml:1', 'ops/b.sh:1', 'docs/oldname_notes.md',
                                                 'c.rb:1', 'c.rb:2')
    end

    it 'reports locations, never the word' do
      result = findings({ 'a.txt' => "prod.secret.example\n" }).join

      expect(secret_words.none? { |word| result.include?(word) }).to be(true)
    end

    it 'finds nothing in ordinary text, and nothing with another key' do
      expect(findings({ 'a.rb' => "class Ticket; host = 'example.com'; end\n" })).to eq([])
      expect(described_class.findings({ 'a.yml' => "host: prod.secret.example\n" }, key: 'other', digests: digests))
        .to eq([])
    end
  end

  describe '.forbidden_file' do
    it 'refuses files that hold secrets or data by nature' do
      paths = %w[.env config/master.key config/credentials/production.key .pgpass db/dump.sql x.sqlite3
                 production.log .gitleaksignore .env.local db/dump.sql.gz backup.zip .envrc vault.kdbx]

      expect(paths.reject { |path| described_class.forbidden_file(path) }).to eq([])
    end

    it 'lets example env files and code through' do
      paths = %w[.env.example .env.docker.example .env.self-host.example app/models/ticket.rb config/database.yml]

      expect(paths.select { |path| described_class.forbidden_file(path) }).to eq([])
    end

    it 'allows only an empty placeholder in a runtime directory' do
      expect(described_class.forbidden_file('storage/.keep', size: 0)).to be_nil
      expect(described_class.forbidden_file('storage/.keep', size: 3)).to eq('runtime data')
      expect(described_class.forbidden_file('tmp/x.txt')).to eq('runtime data')
    end

    # Review of #969, point 11: only the runtime directories of the application itself.
    it 'lets code in a directory of the same name through' do
      expect(%w[app/services/storage/x.rb app/javascript/log/x.js spec/tmp/x_spec.rb]
               .select { |path| described_class.forbidden_file(path) }).to eq([])
    end
  end

  # Runs everywhere, without the key: the list must exist and be digests, or
  # the workflow checks nothing.
  describe 'the digests file of this repository' do
    let(:lines) do
      described_class.read_digests(File.read(File.expand_path("../../../#{described_class::DIGESTS_FILE}", __dir__)))
    end

    it 'lists digests, one 64-digit hex value per line, and nothing in plain text' do
      expect(lines).not_to be_empty
      expect(lines.grep_v(/\A\h{64}\z/)).to eq([])
    end

    it 'carries the key check' do
      text = File.read(File.expand_path("../../../#{described_class::DIGESTS_FILE}", __dir__))

      expect(text.scan(described_class::KEY_CHECK_LINE).size).to eq(1)
    end
  end
end

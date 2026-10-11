# frozen_string_literal: true

require 'openssl'

module Lalabase
  # Keeps what only the maintainers know out of this public repository: our
  # host names, server addresses, private mail addresses, the storage box, and
  # the distinctive names in our server paths (a path itself, with its /, is no
  # token). Run on every pull request by script/leak_guard
  # (.github/workflows/leaks.yml), next to gitleaks for secrets.
  #
  # The repository cannot name what it must not contain, so it holds keyed
  # digests (HMAC-SHA256) of those words, not the words. Plain digests would
  # not do: an IP address or a six-digit account number is found again from
  # its digest in seconds. The key lives in the CI secret LEAK_GUARD_KEY and in
  # the maintainers' .env; the plain list lives in the private repository.
  #
  # Plain Ruby, no Rails: the workflow runs it without a bundle.
  #
  # Entry point: tokens, forbidden_file, findings, history_records, raw_entries, gitleaks_config_problems
  module LeakGuard
    DIGESTS_FILE = 'config/leak_guard.digests'
    # The digest of a fixed word, next to the others: a key that does not
    # yield it is the wrong key, and a wrong key finds nothing.
    KEY_CHECK_WORD = 'lalabase-leak-guard-key-check'
    KEY_CHECK_LINE = /^key-check (\h{64})$/

    # Files that hold secrets or data by their nature, wherever they sit.
    FORBIDDEN_FILES = [
      %r{(\A|/)\.env\z},
      %r{(\A|/)\.env\.(?!(?:[\w-]+\.)?example\z)[^/]+\z},
      %r{(\A|/)credentials(/[^/]+)?\.yml\.enc\z},
      %r{(\A|/)id_(rsa|ed25519|ecdsa)\z},
      %r{(\A|/)(?:\.netrc|_netrc|\.pgpass|\.my\.cnf|\.git-credentials|\.htpasswd|\.gitleaksignore|\.envrc)\z},
      /\.(?:key|pem|p12|pfx|jks|keystore|kdbx|bak|sql|dump|sqlite3?|db|log|zip|7z|tgz)\z/i,
      /\.(?:sql|dump|tar)\.(?:gz|bz2|xz|zst)\z/i
    ].freeze
    # The runtime directories of the application: only an empty placeholder
    # is tracked. At the root only; app/services/storage/ is code.
    RUNTIME_DIR = %r{\A(?:storage|log|tmp)/}
    RUNTIME_PLACEHOLDERS = %w[.keep .gitkeep].freeze

    # Mail addresses and dotted names (hosts, IPv4), and words. An address
    # also yields its domain, a dotted name every run of two or more of its
    # labels, also with the first label cut after its last - or _ and the
    # last cut before its first: the host inside "deploy@prod.example",
    # "www.prod.example.com" or "the prod.example-server" is a token of its
    # own. Words come with and without _ and - inside (an_old_name, and old in
    # it, and oldname), as the runs of their CamelCase parts (OldNameService:
    # oldname), umlauts included. An address also comes without its +tag.
    COMPOUND = /[[:alnum:]_.+-]+@[[:alnum:]_-]+(?:\.[[:alnum:]_-]+)+|[[:alnum:]_-]+(?:\.[[:alnum:]_-]+)+/
    WORDS = [/[[:alnum:]]+/, /[[:alnum:]_-]+/].freeze
    CAMEL_PART = /[[:upper:]]?[[:lower:][:digit:]]+|[[:upper:]]+(?![[:lower:]])/
    PLUS_TAG = /\A([^@+]+)\+[^@]*(@.+)\z/
    # Also glued to a flag (-h203.0.113.77), with leading zeros, with dashes
    # (ip-203-0-113-77), and reversed for reverse DNS.
    IPV4 = /(?<!\d)\d{1,3}(?:([.-])\d{1,3}){3}(?!\d)/
    PERCENT_ESCAPE = /%(\h\h)/

    module_function

    # The text as written, and with \. and %XX undone: a host in a pattern,
    # an address in a URL.
    def tokens(text)
      [text, decode(text)].uniq.flat_map { |variant| raw_tokens(variant) }.map(&:downcase).uniq
    end

    def decode(text)
      text.gsub('\\.', '.').gsub(PERCENT_ESCAPE) do
        char = Regexp.last_match(1).hex.chr
        char.match?(/[[:graph:]]/) ? char : Regexp.last_match(0)
      end
    end

    def raw_tokens(text)
      found = WORDS.flat_map { |re| text.scan(re) }
      found.concat(found.grep(/[_-]/).map { |word| word.delete('_-') })
      found.concat(text.scan(WORDS.first).flat_map { |word| camel_runs(word) })
      text.scan(COMPOUND).each do |compound|
        found.push(compound, *dotted_parts(compound))
        found << compound.sub(PLUS_TAG, '\\1\\2') if compound.match?(PLUS_TAG)
      end
      found.concat(ipv4_addresses(text))
    end

    def ipv4_addresses(text)
      text.to_enum(:scan, IPV4).flat_map do
        octets = Regexp.last_match(0).split(/[.-]/).map(&:to_i)
        [octets.join('.'), octets.reverse.join('.')]
      end
    end

    def camel_runs(word)
      parts = word.scan(CAMEL_PART)
      return [] if parts.size < 2

      (0...parts.size).flat_map { |from| (from...parts.size).map { |to| parts[from..to].join } }
    end

    def dotted_parts(compound)
      labels = compound.split('@', 2).last.split('.')
      (0...labels.size).flat_map do |from|
        ((from + 1)...labels.size).flat_map do |to|
          firsts = [labels[from], labels[from][/[^_-]+\z/]].compact.uniq
          lasts = [labels[to], labels[to][/\A[^_-]+/]].compact.uniq
          firsts.product(lasts).map { |first, last| [first, *labels[(from + 1)...to], last].join('.') }
        end
      end
    end

    # Whether a word can be found at all: the tokenizer yields it as it is.
    # A word with / or : or a space never would.
    def matchable?(word) = tokens(word).include?(word.downcase)

    def digest(key, token) = OpenSSL::HMAC.hexdigest('SHA256', key, token.downcase)

    def key_check(key) = digest(key, KEY_CHECK_WORD)

    def key_matches?(key, digests_text) = digests_text[KEY_CHECK_LINE, 1] == key_check(key)

    # A value from an env file: bare, quoted, or after export.
    def env_value(text, name)
      value = text[/^(?:export\s+)?#{Regexp.escape(name)}=(.*)$/, 1]&.strip or return
      value[/\A(["'])(.*)\1\z/, 2] || value
    end

    # Why a path may not be tracked, or nil.
    def forbidden_file(path, size: 0)
      return 'holds secrets or data by nature' if FORBIDDEN_FILES.any? { |re| re.match?(path) }
      return unless RUNTIME_DIR.match?(path)
      return 'runtime data' unless RUNTIME_PLACEHOLDERS.include?(File.basename(path))

      'runtime data' if size.positive?
    end

    # files: { location => text }. Returns where a token whose keyed digest is
    # listed stands ("location:line", or the location when its own name
    # matches). The token is never printed on its own, since a CI log is
    # public; a matching file name is its own location, which the pull
    # request shows anyway.
    def findings(files, key:, digests:)
      listed = digests.to_set
      known = Hash.new { |cache, token| cache[token] = listed.include?(digest(key, token)) }
      files.flat_map do |path, text|
        hits = tokens(path).any? { |t| known[t] } ? [path] : []
        text.each_line.with_index(1) do |line, number|
          hits << "#{path}:#{number}" if tokens(line).any? { |t| known[t] }
        end
        hits
      end
    end

    # Bytes as text to read: NUL bytes dropped (a text behind one, or UTF-16
    # with its ASCII), invalid UTF-8 replaced. A binary file reads as noise,
    # which matches nothing.
    def readable(data) = data.b.delete("\0").force_encoding(Encoding::UTF_8).scrub

    # The output of git diff-tree -r -z --raw as [status, new mode, path]; a
    # rename or copy by its new path. No path is parsed: -z leaves them as
    # they are.
    def raw_entries(output)
      fields = output.split("\0")
      entries = []
      while (meta = fields.shift)&.start_with?(':')
        _, mode, _, _, status = meta.delete_prefix(':').split
        paths = [fields.shift]
        paths << fields.shift if status.start_with?('R', 'C')
        entries << [status[0], mode, paths.last]
      end
      entries
    end

    # The format script/leak_guard gives git log -p -U0 --text
    # --diff-merges=first-parent, with a marker that is new on every run: a
    # line per commit, one with who wrote and committed it (an address from
    # another machine or an agent's environment is public too), and one after
    # its message. A diff line starts with +,
    # -, a space, \ or a fixed header word, and a message cannot know the
    # marker, so nothing in a commit can end a record early.
    def log_format(marker) = "#{marker} %H%n#{marker}-who %an <%ae> / %cn <%ce>%n%B%n#{marker}-end"

    # That log, line by line, as one { location => text } per commit: its
    # message, and per file the lines it added (for a merge: what it added to
    # the first parent, a conflict resolution included). Removed lines are
    # not news. Read as a stream: the whole history does not fit in memory.
    def history_records(lines, marker:)
      return enum_for(__method__, lines, marker: marker) unless block_given?

      commit_line = /\A#{Regexp.escape(marker)} (\h{40})$/
      end_line = "#{marker}-end\n"
      who_line = "#{marker}-who "
      texts = commit = path = state = nil
      lines.each do |line|
        if (sha = line[commit_line, 1])
          yield texts if texts
          commit = sha[0, 10]
          texts = { "#{commit} (message)" => +'' }
          state = :message
        elsif state == :message && line.start_with?(who_line)
          texts = { "#{commit} (identity)" => line.delete_prefix(who_line), **texts }
        elsif state == :message
          next texts["#{commit} (message)"] << line unless line == end_line

          texts["#{commit} (message)"].sub!(/\n+\z/, "\n")
          state = :diff
        elsif line.start_with?('diff --git ')
          state = :header
        elsif state == :header && line.start_with?('+++ ')
          path = diff_path(line)
        elsif line.start_with?('@@')
          state = :hunk
        elsif state == :hunk && line.start_with?('+')
          (texts["#{commit} #{path} (added)"] ||= +'') << line[1..]
        end
      end
      yield texts if texts
    end

    # A path from a +++ line, with core.quotePath=false: git appends a tab
    # after a path with a space, and still quotes one with " or \.
    def diff_path(line)
      path = line.chomp.delete_prefix('+++ ').chomp("\t")
      path = path[1..-2] if path.start_with?('"') && path.end_with?('"')
      path.delete_prefix('b/')
    end

    # What would make gitleaks skip something: exceptions by path or commit,
    # the upstream defaults ([extend] brings their exceptions back), and in a
    # global allowlist anything but exact values.
    def gitleaks_config_problems(text)
      problems = []
      problems << '[extend] (pulls in the upstream exceptions)' if text.match?(/^\s*\[extend\]/)
      problems << 'paths =' if text.match?(/^\s*paths\s*=/)
      problems << 'commits =' if text.match?(/^\s*commits\s*=/)
      text.scan(/^\[\[allowlists\]\]\n(.*?)(?=^\[|\z)/m).flatten.each do |block|
        problems << 'stopwords in a global allowlist' if block.match?(/^\s*stopwords\s*=/)
        values = block[/^\s*regexes\s*=\s*\[(.*?)^\s*\]/m, 1].to_s.scan(/'''(.*?)'''/).flatten
        values.reject { |value| value.match?(/\A\^[A-Za-z0-9_-]+\$\z/) }.each do |value|
          problems << "a global allowlist value that is not exact: '''#{value}'''"
        end
      end
      problems
    end

    # The digests file: one hex digest per line, # for comments, and the key check.
    def read_digests(text)
      text.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') || l.match?(KEY_CHECK_LINE) }
    end
  end
end

# frozen_string_literal: true

require 'date'

module Lalabase
  # Releases of the core: the version scheme, the draft notes built from merged
  # pull requests, and the edits script/release makes to CHANGELOG.md.
  #
  # Versions are dates: YEAR.MONTH.PATCH, the month without a leading zero
  # (2026.11.0, 2027.1.0). The first release of a month is .0; a second one in
  # the same month, usually a security fix, counts up (2026.11.1). main is what
  # our cloud runs; self-hosters install releases.
  #
  # Plain Ruby, no Rails: script/release loads this file directly.
  #
  # Entry point: next_version, draft, insert, section
  module Release
    VERSION = /\A(\d{4})\.([1-9]|1[0-2])\.(\d+)\z/
    UNRELEASED = '## [Unreleased]'
    UNRELEASED_LINE = /^## \[Unreleased\]$/
    VERSION_HEADING = /^## \[(?<version>[^\]]+)\] - (?<date>\d{4}-\d{2}-\d{2})$/
    # A pull request title in the conventional shape: "feat(tickets): one task".
    TITLE = /\A(?<type>[a-z]+)(?:\([^)]*\))?(?<breaking>!)?:\s*(?<text>.+)\z/
    # How a pull request shows in a commit subject: a merge commit ("Merge pull
    # request #966 from …") or a squash merge ("fix: the count (#41)").
    MERGE_SUBJECT = /\AMerge pull request #(\d+) from /
    SQUASH_SUBJECT = /\(#(\d+)\)\s*\z/
    # Where prepare drafted from: publish holds every pull request after it
    # against the notes.
    DRAFTED_FROM = /^<!-- drafted from (\h{40}) -->$/
    # Title type -> CHANGELOG section. Anything else (chore, docs, test, ci, a
    # title without a type) goes to UNSORTED, visibly: about half of the titles
    # have no type, and among them were exactly the ones a self-hoster needs
    # (#954 Dockerfile, #956 a fix). publish refuses while the section exists.
    SECTIONS = {
      'Added' => %w[feat],
      'Changed' => %w[perf refactor],
      'Fixed' => %w[fix],
      'Security' => %w[security sec]
    }.freeze
    FIRST_RELEASE = 'First public release.'
    UNSORTED = '### Unsorted (move or delete before publishing)'
    # The image .github/workflows/docker-release.yml publishes for each release.
    IMAGE = 'ghcr.io/lalabase/lalabase'
    # The line of compose.yml that names the image of its release. prepare
    # writes the version into it and publish holds it against the version, so
    # a checked-out tag pulls the image built from that tag.
    COMPOSE_IMAGE = /^(?<lead>\s*image: #{Regexp.escape(IMAGE)}:\$\{LALABASE_VERSION:-)(?<version>[^}]*)(?<tail>\})$/

    module_function

    def version?(value) = VERSION.match?(value.to_s)

    # The highest version among names (tags), or nil.
    def latest(names)
      names.select { |name| version?(name) }.max_by { |name| name.split('.').map(&:to_i) }
    end

    def next_version(existing, today:)
      month = "#{today.year}.#{today.month}"
      patches = existing.select { |name| version?(name) && name.start_with?("#{month}.") }
                        .map { |name| name.split('.').last.to_i }
      "#{month}.#{patches.empty? ? 0 : patches.max + 1}"
    end

    # The pull requests in a range of commits, read off every subject (`git log
    # <tag>..HEAD --format=%s`, all parents): merge commits, squash merges and
    # the inner pull requests of a stack. Commits, not times: a time comparison
    # lost pull requests to time zones. THE one rule of what a release holds;
    # draft and publish both ask it.
    def pull_request_numbers(subjects)
      subjects.filter_map { |subject| (subject[MERGE_SUBJECT, 1] || subject[SQUASH_SUBJECT, 1])&.to_i }.uniq
    end

    def drafted_from(section) = section.to_s[DRAFTED_FROM, 1]

    # The pull requests a section names, as (#N) the way the draft writes them.
    def mentioned_numbers(section) = section.to_s.scan(/\(#(\d+)\)/).flatten.map(&:to_i).uniq

    # The release notes as GitHub shows them: the section without HTML comments.
    def notes(section) = section.gsub(/^<!--.*?-->\n*/m, '').strip

    # The release compose.yml pulls, or nil unless it names the image exactly once.
    def compose_version(text)
      versions = text.to_s.to_enum(:scan, COMPOSE_IMAGE).map { Regexp.last_match[:version] }
      versions.first if versions.one?
    end

    def with_compose_version(text, version)
      count = text.to_s.scan(COMPOSE_IMAGE).size
      raise ArgumentError, "compose.yml names #{IMAGE} #{count} times, not once" unless count == 1

      text.sub(COMPOSE_IMAGE) { "#{Regexp.last_match[:lead]}#{version}#{Regexp.last_match[:tail]}" }
    end

    # A diff of compose.yml (`git diff -U0`) that changes nothing but the
    # version of the release image: what prepare does, and nothing a
    # self-hoster has to compare with their copy.
    def version_only_diff?(diff)
      changed = diff.to_s.lines.drop_while { |line| !line.start_with?('@@') }.grep(/\A[-+]/)
      changed.any? && changed.all? { |line| COMPOSE_IMAGE.match?(line[1..].chomp) }
    end

    # Titles marked breaking ("feat(api)!: …"), as upgrade notes.
    def breaking_changes(pull_requests)
      pull_requests.filter_map do |pr|
        match = TITLE.match(pr[:title].to_s.strip)
        "Breaking change, read before updating: #{match[:text]} (##{pr[:number]})" if match&.[](:breaking)
      end
    end

    # pull_requests: [{ number:, title: }]. Returns { 'Added' => [...], …, 'Other' => [...] }.
    def categorize(pull_requests)
      pull_requests.each_with_object(Hash.new { |h, k| h[k] = [] }) do |pr, sections|
        match = TITLE.match(pr[:title].to_s.strip)
        section = match && SECTIONS.find { |_, types| types.include?(match[:type]) }&.first
        text = match ? match[:text] : pr[:title].to_s.strip
        sections[section || 'Other'] << "#{text} (##{pr[:number]})"
      end
    end

    # The CHANGELOG block of one release. Without a previous release it is the
    # first public one; upgrade_hints are what a self-hoster has to do.
    def draft(version, date, pull_requests, first: false, upgrade_hints: [], drafted_from: nil)
      lines = ["## [#{version}] - #{date}", '']
      lines.push("<!-- drafted from #{drafted_from} -->", '') if drafted_from
      if first
        lines.push('### Added', '', "- #{FIRST_RELEASE}", '')
      else
        sections = categorize(pull_requests)
        SECTIONS.each_key do |name|
          next if sections[name].empty?

          lines.push("### #{name}", '', *sections[name].map { |item| "- #{item}" }, '')
        end
        other = sections['Other']
        lines.push(UNSORTED, '', *other.map { |item| "- #{item}" }, '') unless other.empty?
      end
      hints = (first ? [] : breaking_changes(pull_requests)) + upgrade_hints
      lines.push('### Upgrade notes', '', *(hints.empty? ? ['- None.'] : hints.map { |h| "- #{h}" }), '')
      lines.join("\n")
    end

    # Puts the block under [Unreleased]. What stood there moves into the block:
    # free text first, a section the block has too ("### Upgrade notes") into
    # that section, any other section before the upgrade notes. A hand-written
    # upgrade note replaces the draft's "None.".
    def insert(changelog, block)
      start = changelog.index(UNRELEASED_LINE) or raise ArgumentError, "#{UNRELEASED} is missing"
      body_start = start + UNRELEASED.length
      body_end = changelog.index(/^## \[/, body_start) || changelog.length
      merged = merge_unreleased(block, changelog[body_start...body_end])
      "#{"#{changelog[0...body_start]}\n\n#{merged.rstrip}\n\n#{changelog[body_end..].to_s.lstrip}".rstrip}\n"
    end

    def merge_unreleased(block, unreleased)
      heading, rest = block.split("\n", 2)
      mark = rest[/\A\s*(#{DRAFTED_FROM.source})\n/, 1]
      rest = rest.sub(/\A\s*#{DRAFTED_FROM.source}\n/, '') if mark
      ours = parts(rest)
      theirs = parts(unreleased)
      theirs.each do |title, body|
        next if body.strip.empty?

        if title && (own = ours.find { |t, _| t == title })
          own[1] = title == '### Upgrade notes' ? body.strip : "#{own[1].strip}\n#{body.strip}"
        elsif title
          ours.insert(ours.index { |t, _| t == '### Upgrade notes' } || ours.size, [title, body.strip])
        else
          ours.unshift([nil, body.strip])
        end
      end
      [heading, ('' if mark), mark, '', *ours.flat_map { |t, body| [t, ('' if t), body.strip, ''] }].compact.join("\n")
    end

    # A section body split at its "### " headings: [[heading or nil, text], ...].
    def parts(body)
      body.to_s.split(/^(?=### )/).filter_map do |chunk|
        next if chunk.strip.empty?

        title = chunk[/\A### .*$/]
        [title, title ? chunk.sub(title, '') : chunk]
      end
    end

    # The text under any second-level heading (e.g. UNRELEASED), up to the next one.
    def section_body(changelog, heading)
      start = changelog.index(/^#{Regexp.escape(heading)}$/) or return ''
      body_end = changelog.index(/^## /, start + heading.length) || changelog.length
      changelog[(start + heading.length)...body_end].strip
    end

    # The text of one release's section, without its heading (the release notes).
    def section(changelog, version)
      heading = changelog.match(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/) or return
      body_end = changelog.index(/^## \[/, heading.end(0)) || changelog.length
      changelog[heading.end(0)...body_end].strip
    end

    # Everything wrong with the shape of a CHANGELOG, as messages; empty when
    # script/release can work with it. The CHANGELOG guard spec and publish both
    # ask: a pull request touching only CHANGELOG.md skips guards.yml.
    def problems(text)
      headings = text.scan(/^## .*$/)
      releases = text.to_enum(:scan, VERSION_HEADING).map { Regexp.last_match }
      versions = releases.map { |m| m[:version] }
      [
        ('Unreleased is not the first section' unless headings.first == UNRELEASED),
        *headings.drop(1).grep_v(VERSION_HEADING).map { |h| "not a release heading: #{h}" },
        *versions.reject { |v| version?(v) }.map { |v| "not a version: #{v}" },
        ('a version appears twice' unless versions == versions.uniq),
        ('releases are not newest first' unless versions == versions.sort_by { |v| v.split('.').map(&:to_i) }.reverse),
        *releases.reject { |m| valid_date?(m[:date]) }.map { |m| "not a date: #{m[:date]}" },
        *versions.flat_map { |v| section_problems(v, section(text, v).to_s) }
      ].compact
    end

    def section_problems(version, body)
      titles = body.scan(/^### .*$/)
      upgrade = body[/^### Upgrade notes\n(.*?)(?=^### |\z)/m, 1].to_s
      [
        ("no upgrade notes: #{version}" unless titles.include?('### Upgrade notes')),
        ("unsorted entries left: #{version}" if titles.include?(UNSORTED)),
        *titles.tally.select { |_, n| n > 1 }.keys.map { |t| "#{version} has #{t} twice" },
        ("#{version}: \"None.\" beside real upgrade notes" if upgrade.include?('- None.') && upgrade.scan(/^- /).size > 1)
      ]
    end

    def valid_date?(value)
      Date.iso8601(value)
      true
    rescue Date::Error
      false
    end
  end
end

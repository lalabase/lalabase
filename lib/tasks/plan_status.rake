# frozen_string_literal: true

require 'json'
require 'open3'

# Regenerates the machine-written "Umsetzung" marker at the top of every doc/*.md plan.
#
# The marker records EVIDENCE, never a verdict. Implementation can be proven automatically
# but not disproven: doc/ticket_chat_plan.md declares itself "DRAFT" while #207-#210 shipped
# the feature, and doc/inbox_feature_spec.md says "nicht in Umsetzung" while #10/#11/#67/#160
# are merged. A marker reading "OFFEN" would therefore be worse than none -- it would assert
# something the data cannot support. Hence the deliberately negative phrasing of the
# no-evidence case.
#
# Two independent signals, because neither alone is reliable:
#   A) a feat/fix/refactor commit touched the plan file
#      -> misses plans implemented without anyone updating the plan
#   B) the plan's own header names a merged feature PR
#      -> misses plans whose header predates the implementation (13 exclusive hits)
# A weak third signal (filename topic matched against merged PR titles) only ever downgrades
# a no-evidence case to "unklar"; on its own it produces false positives.
#
# The date in the marker is the date the EVIDENCE last changed, not the date of the last run.
# Re-running when nothing shipped must produce an empty diff, otherwise `git diff` after a run
# cannot distinguish "nothing changed" from "everything changed".
#
# Usage:
#   bin/rails plan_status:refresh   # rewrite markers, report what changed
#   bin/rails plan_status:check     # dry run, non-zero exit when markers are stale (CI-able)
#
# Both accept an optional file or glob, so touching ONE plan does not rewrite all of them
# (a full run rewrites >100 files and buries the edit it was meant to record):
#   bin/rails "plan_status:refresh[doc/ki_bereich_navigation_plan.md]"
#   bin/rails "plan_status:check[doc/ki_*.md]"
# A bare name resolves inside doc/, so "plan_status:refresh[ki_pakete_plan.md]" works too.
# A pattern matching nothing ABORTS: reporting "all current" for a typo'd path is the one
# failure mode this task must not have -- it would look exactly like success. Same reasoning
# guards a saturated `gh pr list` (PR_LIMIT) and a failing `git log` (commits_for).
#
# BEFORE wiring :check into CI, two prerequisites -- neither is met by guards.yml today:
#   * actions/checkout needs `fetch-depth: 0`. The default depth of 1 leaves signal A with a
#     single commit, so ~103 "belegt" markers would flip to "kein Beleg" and the check would
#     report drift that does not exist.
#   * `gh` needs GH_TOKEN, otherwise pull_requests aborts on the empty response.
module PlanStatus
  MARK_OPEN = '<!-- umsetzungs-status: automatisch ermittelt %s -->'
  MARK_CLOSE = '<!-- /umsetzungs-status -->'
  BLOCK_RE = /<!-- umsetzungs-status: automatisch ermittelt (\d{4}-\d{2}-\d{2}) -->\n(.*?)\n#{Regexp.escape(MARK_CLOSE)}\n*/m
  FEATURE_RE = /\A(feat|fix|refactor|perf)/i
  PLAN_DIR = 'doc'
  PLAN_GLOB = "#{PLAN_DIR}/*.md".freeze
  HEADER_LINES = 15
  # Deliberately far above the current PR count (425 on 2026-08-03). The value only has to
  # stay ahead of the repo; pull_requests aborts rather than write from a saturated list.
  PR_LIMIT = 2000

  # Filename words that describe the document type rather than its subject; keeping them
  # would match unrelated PRs ("plan", "spec" appear in many titles).
  TOPIC_STOPWORDS = %w[
    plan spec analyse audit entwurf matrix checklist inventur fixes summary handoff prompt
    runbook playbook
  ].freeze

  module_function

  def pull_requests
    json = `gh pr list --state all --limit #{PR_LIMIT} --json number,state,title,mergedAt 2>/dev/null`
    abort 'plan_status: `gh` lieferte keine Daten — angemeldet? (gh auth status)' if json.strip.empty?

    list = JSON.parse(json)
    # A saturated answer is by definition incomplete, and silently incomplete is the one
    # thing this task must not be: `gh pr list` returns NEWEST first, so the limit drops the
    # OLDEST PRs -- precisely the ones the older plans reference. Markers written from a
    # truncated map would lose the "zuletzt gemergt" suffix on every affected plan and get
    # restamped with today's date: a sweeping diff with no triggering event, and a red
    # `check` nobody caused. Same failure class as the typo'd path pattern -- refuse.
    abort "plan_status: `gh` lieferte #{list.size} PRs = das Limit — Liste abgeschnitten, PR_LIMIT erhöhen." if list.size >= PR_LIMIT

    list.index_by { |pr| pr['number'] }
  rescue JSON::ParserError => e
    abort "plan_status: PR-Liste nicht lesbar (#{e.message})"
  end

  # Own method so the failure is a failure: backticks swallow the exit status, and a failed
  # `git log` returning "" is indistinguishable from "this file has no commits" -- which the
  # marker would report as "kein Beleg gefunden". Explicit args also mean a plan name with a
  # space or a bracket reaches git intact instead of being word-split by the shell.
  def commits_for(path)
    out, err, status = Open3.capture3('git', 'log', '--format=%ad^%s', '--date=short', '--', path)
    abort "plan_status: `git log` für #{path} fehlgeschlagen: #{err.strip}" unless status.success?

    out.lines.map(&:chomp)
  end

  # @return [Hash] :prs, :verdict, :last_merge, :last_impl, :weak
  def evidence(path, prs)
    commits = commits_for(path)
    impl = commits.select { |line| line.split('^', 2)[1].to_s.match?(FEATURE_RE) }
    found = (commit_prs(impl) + header_prs(path, prs)).uniq.sort
    verdict = verdict_for(found, impl)

    {
      prs: found,
      verdict: verdict,
      last_merge: found.filter_map { |number| prs.dig(number, 'mergedAt') }.max.to_s[0, 10],
      # The LAST IMPLEMENTATION commit, not the last commit of any kind -- the marker's own
      # docs: commit would otherwise overwrite the date it is supposed to report.
      # max, not first: %ad is the AUTHOR date while `git log` orders by COMMIT date, and a
      # rebase pulls those apart -- the newest line is then not the latest date.
      last_impl: impl.filter_map { |line| line.split('^', 2).first.presence }.max.to_s,
      weak: verdict == :no_evidence ? thematic_prs(path, prs) : []
    }
  end

  def verdict_for(found, impl)
    return :proven if found.any?
    return :proven_without_pr if impl.any?

    :no_evidence
  end

  def commit_prs(impl)
    impl.filter_map { |line| line[/\(#(\d+)\)\s*\z/, 1]&.to_i }
  end

  # Reads the header WITHOUT the marker block. The block lists the very PR numbers this
  # signal looks for, so leaving it in would let the marker feed itself: every "unklar"
  # would be promoted to "belegt" on the next run and could never fall back.
  def header_prs(path, prs)
    header = File.read(path).sub(BLOCK_RE, '').lines.first(HEADER_LINES).join
    header.scan(/#(\d+)/).flatten.map(&:to_i).uniq.select do |number|
      pr = prs[number]
      pr && pr['state'] == 'MERGED' && pr['title'].to_s.match?(FEATURE_RE)
    end
  end

  # Weak signal: at least two topic words from the filename co-occurring in a merged
  # feature PR title. Never promotes to :proven -- it only annotates a no-evidence case.
  def thematic_prs(path, prs)
    words = topic_words(path)
    return [] if words.size < 2

    hits = prs.values.select do |pr|
      title = pr['title'].to_s.downcase
      pr['state'] == 'MERGED' && title.match?(FEATURE_RE) &&
        words.count { |word| title.include?(word) } >= 2
    end
    # last(6), not first(6): this signal exists so a HUMAN can judge relevance, and for that
    # the most recent PRs are the useful ones -- the six oldest thematic hits are the least
    # likely to be the implementation. (proven_text keeps first(8): there it reads as the
    # chronology of an actual implementation.)
    hits.map { |pr| pr['number'] }.sort.last(6)
  end

  def topic_words(path)
    File.basename(path, '.md')
        .sub(/_\d{4}[_-]\d{2}[_-]\d{2}\z/, '')
        .split('_')
        .reject { |word| word.length <= 2 || TOPIC_STOPWORDS.include?(word) }
  end

  def marker_body(data)
    case data[:verdict]
    when :proven then proven_text(data)
    when :proven_without_pr
      "**Umsetzung:** belegt — Umsetzungs-Commits auf diese Datei (zuletzt #{data[:last_impl]}), ohne PR-Nummer im Betreff."
    else weak_or_none(data)
    end
  end

  def proven_text(data)
    refs = data[:prs].first(8).map { |number| "##{number}" }.join(', ')
    merged = data[:last_merge].empty? ? '' : ", zuletzt gemergt #{data[:last_merge]}"
    "**Umsetzung:** belegt — #{refs}#{merged}. Der Code ist die maßgebliche Quelle, nicht dieses Dokument."
  end

  def weak_or_none(data)
    return no_evidence_text if data[:weak].empty?

    refs = data[:weak].map { |number| "##{number}" }.join(', ')
    "**Umsetzung:** unklar — kein direkter Beleg, aber thematisch passende gemergte PRs (#{refs}). Vor Nutzung gegen den Code prüfen."
  end

  def no_evidence_text
    '**Umsetzung:** kein Beleg gefunden — weder ein Umsetzungs-Commit auf diese Datei noch eine gemergte PR-Nennung. ' \
      '**Das ist kein Nachweis, dass nichts umgesetzt wurde**; eine etwaige Status-Angabe unten ist ungeprüft.'
  end

  # @return [String, nil] the rewritten document, or nil when the marker is already current
  def rewritten(path, body, today)
    original = File.read(path)
    previous = original.match(BLOCK_RE)
    # Keep the recorded date when the evidence itself is unchanged -- the marker dates the
    # finding, not the run.
    stamp = previous && previous[2] == body ? previous[1] : today
    updated = insert_block(original, "#{format(MARK_OPEN, stamp)}\n#{body}\n#{MARK_CLOSE}\n")
    updated == original ? nil : updated
  end

  # Drops any previous block first, so a rerun replaces rather than stacks, and normalises
  # the spacing to H1 / blank / block / blank / rest. Without the normalisation a block
  # removed by hand round-trips to a doubled blank line instead of the original bytes.
  def insert_block(original, block)
    lines = original.sub(BLOCK_RE, '').split("\n", -1)
    heading = lines.index { |line| line.start_with?('# ') }
    return "#{block}\n#{strip_leading_blanks(lines).join("\n")}" if heading.nil?

    rest = strip_leading_blanks(lines.drop(heading + 1))
    "#{lines.take(heading + 1).join("\n")}\n\n#{block}\n#{rest.join("\n")}"
  end

  def strip_leading_blanks(lines)
    lines.drop_while { |line| line.strip.empty? }
  end

  # Resolves the optional task argument to the set of plans to work on.
  # nil                       -> every plan (the original behaviour)
  # "doc/foo.md" / "doc/*.md" -> used as given
  # "foo.md" / "ki_*.md"      -> resolved inside doc/, so the common case needs no prefix
  #
  # Aborts on an empty match instead of returning [], because report/0 would then print
  # "alle Marker aktuell" -- indistinguishable from a successful run.
  def paths(pattern)
    # The internal plans moved to lalabase-private. An absent archive is not a clean run.
    abort 'plan_status: doc/ wurde nach lalabase-private verschoben. Diese lokale Task ist ohne Planarchiv nicht verfügbar; keine Pläne in den Kern zurückkopieren.' unless Dir.exist?(PLAN_DIR)

    return Dir[PLAN_GLOB].sort if pattern.to_s.strip.empty?

    pattern = pattern.strip
    candidate = pattern.include?('/') ? pattern : File.join(PLAN_DIR, pattern)
    matches = Dir[candidate].select { |path| File.file?(path) }.sort
    abort "plan_status: kein Plan passt auf '#{pattern}' (gesucht: #{candidate})" if matches.empty?

    # refresh WRITES. Without this, `plan_status:refresh[../../*.md]` rewrites files outside
    # doc/, and a symlink under doc/ would carry the write to its target -- hence realpath,
    # which resolves both. The argument is a convenience, not an escape hatch.
    outside = matches.reject { |path| inside_plan_dir?(path) }
    abort "plan_status: liegt außerhalb von #{PLAN_DIR}/: #{outside.join(', ')}" if outside.any?

    matches
  end

  def inside_plan_dir?(path)
    File.realpath(path).start_with?("#{File.realpath(PLAN_DIR)}/")
  rescue Errno::ENOENT
    false
  end

  def run(write:, pattern: nil)
    selected = paths(pattern)
    prs = pull_requests
    today = Time.zone.now.strftime('%Y-%m-%d')
    changed = selected.filter_map do |path|
      updated = rewritten(path, marker_body(evidence(path, prs)), today)
      next unless updated

      File.write(path, updated) if write
      path
    end
    report(changed, selected, write: write)
    changed
  end

  # Counts report the SELECTED set, not the full glob -- "1 von 132" after passing a single
  # file would read as if 131 plans had been skipped silently.
  def report(changed, selected, write:)
    if changed.empty?
      puts "plan_status: #{selected.size} #{selected.size == 1 ? 'Plan' : 'Pläne'} geprüft, alle Marker aktuell."
      return
    end

    verb = write ? 'aktualisiert' : 'wären zu aktualisieren'
    puts "plan_status: #{changed.size} von #{selected.size} Marker #{verb}:"
    changed.each { |path| puts "  #{path}" }
  end
end

namespace :plan_status do
  desc 'Umsetzungs-Marker neu ermitteln und schreiben; optional [datei-oder-glob], sonst alle doc/*.md'
  task :refresh, [:pattern] => :environment do |_task, args|
    PlanStatus.run(write: true, pattern: args[:pattern])
  end

  desc 'Prüfen, ob die Umsetzungs-Marker aktuell sind (Exit 1, wenn nicht); optional [datei-oder-glob]'
  task :check, [:pattern] => :environment do |_task, args|
    exit 1 if PlanStatus.run(write: false, pattern: args[:pattern]).any?
  end
end

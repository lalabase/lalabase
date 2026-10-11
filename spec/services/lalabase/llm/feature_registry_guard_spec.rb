# frozen_string_literal: true

# What: the three R5 guards of the AI feature registry
#   (doc/ai_feature_registry_plan.md §5.3). One file, three fences:
#
#   Guard A — the raw lanes. Factory.for_chat / Factory.for_embeddings may be
#     called only in the allowlisted files below; every other path routes through
#     Factory.for_feature(key, org), where gate and route read the same registry
#     row. Completes the door set of provider_pin_guard_spec (Factory.build,
#     PROVIDER_CLASSES, <X>Provider.new): those doors choose a provider YOURSELF,
#     these two choose none — they just route featurelessly, which is the quieter
#     way for gate and route to drift apart.
#   Guard B — registry rows and factory callers must map onto each other.
#     Every seam: resolves to a real constant that actually routes (dead-entry
#     killer), and every file that routes is a seam, a seam's ancestor, or an
#     EXCLUDED_CALLERS entry with a reason (unregistered-seam killer). The
#     classify-or-explain contract of UserDataExports::Registry, applied to
#     routing instead of tables. Plus the question presence alone cannot answer:
#     WHICH row does it route on — the literal key at the call site, or the
#     #feature_key the inherited call site reads, must be the seam's own.
#   Guard C — nothing outside its two owners talks to the low-level predicates
#     ai_available? / has_valid_ai_configuration? /
#     has_valid_embedding_configuration?. Callers ask
#     ai_available_for?(:feature), whose Availability can also say WHY (E4).
#     The SURFACE allowlist is EMPTY by plan (E3: "endet bei R5 leer") and stays
#     a constant so growing it is a reviewed diff, not a habit; the wider scan
#     names the two files that define and consume the API.
#
# Guards A and B scan Ruby AND templates. A view is an unlikely place to build a
# provider from, which is precisely what made it the quiet one: with a .rb-only
# glob, a Factory.for_chat planted in a view left every example green.
#
# Why: R1–R4 built the single resolution; these guards are the fence. Without
#   them the registry is a better pattern, not a boundary (plan §7.4) — and the
#   pre-registry convention broke three times in ONE week (plan §1.2).
#
# Deliberately a GREP guard, not an AST scanner — same trade-off as
# provider_pin_guard_spec: it fences off the accidental carry-over, not the
# determined bypass; no pattern would.

require 'rails_helper'

RSpec.describe 'AI feature registry guards (R5)' do
  registry = Lalabase::Llm::FeatureRegistry

  # `\s*(?:&?\.|::)\s*` covers the three ways to spell the same call:
  # RuboCop breaks long chains across lines (`Factory\n  .for_chat(...)`), so a
  # single-line-only pattern goes quietly blind the first time a call nests one
  # level deeper; `&.` is safe navigation; and `Factory::for_chat(...)` is legal
  # Ruby that nobody writes on purpose — which is exactly why a guard has to see
  # it (cross-model review 2026-08-03: zero call sites today, so the hole was
  # silent). The lookbehind keeps unrelated builders whose class name merely
  # ENDS in Factory out.
  lane_receiver = /(?<![A-Za-z0-9_])Factory\s*(?:&?\.|::)\s*/
  # `chat_probe` counts as the chat lane, and it is the entry that needs this fence
  # MOST: it is the gate-free twin of for_chat (S7/L6, doc/ki_bereich_navigation_plan.md),
  # so a caller reaching for it skips the registry AND both gates. It arrived in the same
  # change that moved the probe out of the settings controller, and without this name in
  # the pattern the guard would have gone quiet about the whole door — the allowlist entry
  # would simply have gone stale and been dropped, which reads like progress.
  chat_lane_call = /#{lane_receiver}(?:for_chat|chat_probe)\b/
  embedding_lane_call = /#{lane_receiver}for_embeddings\b/
  # Guard B classifies every way to ROUTE — the featured way and both raw lanes.
  factory_route_call = /#{lane_receiver}(?:for_feature|for_chat|chat_probe|for_embeddings)\b/
  # The KEY a call site names, when it names one literally. `for_feature(key)`
  # with a variable (Meetings::BaseLlmService) yields nothing here on purpose —
  # that case is covered by the #feature_key check instead.
  feature_key_literal = /#{lane_receiver}for_feature\(\s*:(\w+)/
  # Matching the CALL, never a value: ai_available_for? does NOT match (the `?`
  # must follow `available` directly), and neither does the renamed local
  # controller helper ai_feature_available? — pinned in the self-tests below.
  # Hand-maintained list, verified complete against Organisation's actual
  # low-level API on 2026-08-03 (R5 review): these three ARE the predicates,
  # ai_available_for? is the blessed counterpart. A fourth low-level predicate
  # must be added here — nothing couples this list to the model.
  low_level_predicate = /(?<![A-Za-z0-9_])(?:ai_available\?|has_valid_ai_configuration\?|has_valid_embedding_configuration\?)/

  factory_path = 'app/services/lalabase/llm/factory.rb'

  # ---------------------------------------------------------------------------
  # Allowlists — file => reason. Shrink-only: an entry leaves when its caller
  # moves onto for_feature or dies; the stale checks fail on entries that
  # stopped matching, which is what keeps these an honest inventory.
  # ---------------------------------------------------------------------------

  # factory.rb is deliberately NOT on these lists: its own calls are BARE
  # (`for_chat(...)` inside the module), which the qualified pattern does not
  # match — the same mechanism that keeps provider_pin_guard's door 1 empty.
  # Consequence: nothing in app/, lib/ or any template may write
  # `Factory.for_chat` (or `Factory::for_chat`) outside these files, the factory
  # included.
  #
  # `calls:` is the second half of shrink-only, and the half the first draft
  # missed: an entry excuses a FILE, so without a count that file may collect any
  # number of FURTHER raw-lane calls — possibly for a real feature — while "at
  # least one call is still here" stays true (cross-model review 2026-08-03).
  # Every entry is 1 today. A number that has to change is a diff someone reads.
  # R6 shrank both lists to their honest minimum: every registered seam now
  # routes by its own key, so the raw lanes are left to the one caller that is
  # NO feature (the connection probe) and the one that must work when the
  # feature gates say no (the reindexer).
  chat_lane_callers = {
    'app/services/lalabase/llm/connection_check.rb' => {
      calls: 1,
      reason: 'the connection test through the org\'s real resolution — diagnostics, not a feature. ' \
              'MOVED here from ai_settings_controller.rb with S7 and switched to the gate-free ' \
              'Factory.chat_probe (gap L6); still exactly one call, still no registry row'
    }
  }.freeze

  embedding_lane_callers = {
    'app/services/embeddings/organisation_reindexer.rb' => {
      calls: 1,
      reason: 'ops reindex machinery, no registry row by design — see EXCLUDED_CALLERS for the reason'
    }
  }.freeze

  # E3, executed: the plan starts this list with the R1 inventory and ends it
  # EMPTY at R5. It is empty. It stays declared so that the next entry is a
  # reviewed allowlist diff with a reason — not a quiet regression.
  surface_predicate_callers = {}.freeze

  # The plan fences SURFACES, and that was the R1 problem. But since R3 the
  # predicates have no production caller left ANYWHERE (re-verified 2026-08-03),
  # so stopping at views and controllers leaves the same drift one layer down
  # free: a service re-deriving the gate from ai_available? was measured green
  # before this list existed. Widening costs nothing precisely because the
  # answer is two files — and those two are the REASON nothing else may.
  low_level_owners = {
    'app/models/organisation.rb' =>
      'defines them — this IS the low-level API the plan keeps as a comparison side (E3)',
    'app/services/lalabase/llm/feature_registry.rb' =>
      'THE one resolution: chat_failure/embedding_failure ask the credential question once, and ' \
      'every gate and every route then reads that single answer instead of asking again'
  }.freeze

  # ---------------------------------------------------------------------------
  # Shared machinery (provider_pin_guard_spec precedent)
  # ---------------------------------------------------------------------------

  # Whole comment lines do not route anything, and filtering them matters in
  # both directions: an allowlisted file whose call decays into a comment must
  # not stay green, and a file that merely NAMES a pattern in prose must not
  # need an entry. Trailing comments are NOT stripped (a '#' inside a string
  # would misfire); a trailing mention raises a false alarm — loud and rare
  # beats silent.
  ruby_code_of = lambda do |path|
    File.readlines(path).reject { |line| line.lstrip.start_with?('#') }.join
  end

  # Surfaces add ERB comment BLOCKS (<%# ... %>, often multi-line) — the R2/R3
  # history notes live there and legitimately name the old predicates. Stripping
  # the block first is what lets Guard C scan prose-heavy views at all. The
  # line filter afterwards also drops a text line starting with '#'
  # (a `#{...}` continuation at line start would slip through) — accepted, same
  # trade-off as above, and it has never carried a call.
  surface_code_of = lambda do |path|
    File.read(path)
        .gsub(/<%#.*?%>/m, '')
        .lines.reject { |line| line.lstrip.start_with?('#') }
        .join
  end

  # One reader for a mixed tree: a template needs the ERB block stripped BEFORE
  # the line filter, a Ruby file only the line filter. Handing ruby_code_of an
  # .erb file would turn every R2/R3 history note in a view into a false
  # positive — the dispatch is what makes scanning both trees affordable.
  code_of = lambda do |path|
    path.end_with?('.erb') ? surface_code_of.call(path) : ruby_code_of.call(path)
  end

  # .rake on purpose: a backfill/reindex task is the most likely birthplace of a
  # new raw-lane call (OrganisationReindexer is invoked from exactly there).
  #
  # Templates are in as well, and not for symmetry: with a .rb-only glob a view
  # that builds a provider slipped past Guard A AND Guard B (measured
  # 2026-08-03 — a Factory.for_chat planted in a view left all 21 examples
  # green, the same call in a .rb file failed two). A view is an unlikely place
  # to route from, which is exactly what makes it the quiet one.
  scanned_sources = lambda do
    Dir.glob([Rails.root.join('app/**/*.rb'),
              Rails.root.join('app/views/**/*.erb'),
              Rails.root.join('app/components/**/*.erb'),
              Rails.root.join('lib/**/*.rb'),
              Rails.root.join('lib/tasks/**/*.rake')])
  end

  # Presenters, policies, mailers, queries and channels are in, not just the
  # classic view/controller pair: they all assemble or gate what a user gets
  # shown, which makes them exactly the layers that reach for a quick boolean —
  # a Pundit policy deriving an AI affordance from a provider name is the
  # textbook case (adversarial R5 review, MAJOR 1). All were verified clean at
  # inclusion time, so the empty allowlist below cost nothing. (No *.jbuilder in
  # this app — the only non-ERB view is a service worker; re-check when a new
  # template type arrives.)
  scanned_surfaces = lambda do
    Dir.glob([Rails.root.join('app/views/**/*.erb'),
              Rails.root.join('app/controllers/**/*.rb'),
              Rails.root.join('app/helpers/**/*.rb'),
              Rails.root.join('app/presenters/**/*.rb'),
              Rails.root.join('app/policies/**/*.rb'),
              Rails.root.join('app/mailers/**/*.rb'),
              Rails.root.join('app/queries/**/*.rb'),
              Rails.root.join('app/channels/**/*.rb'),
              Rails.root.join('app/components/**/*.rb'),
              Rails.root.join('app/components/**/*.erb')])
  end

  relative_of = lambda do |path|
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end

  offenders_for = lambda do |pattern, allowlist, files, reader|
    files.call.reject { |path| File.symlink?(path) }.filter_map do |path|
      relative = relative_of.call(path)
      next if allowlist.key?(relative)

      relative if reader.call(path).match?(pattern)
    end
  end

  # Not "does it still match" but "how often" — an allowlisted file that grows a
  # second call has changed what the entry excuses, and the entry has to say so.
  # A missing file counts as 0, which is a mismatch too: it must be dropped.
  actual_calls = lambda do |pattern, allowlist, reader|
    allowlist.keys.to_h do |relative|
      path = Rails.root.join(relative)
      [relative, File.exist?(path) ? reader.call(path.to_s).scan(pattern).size : 0]
    end
  end

  expected_calls = lambda do |allowlist|
    allowlist.transform_values { |entry| entry.fetch(:calls) }
  end

  # Where a seam may route OUTSIDE its own source file — an explicit, reasoned
  # list, NOT a blanket "any ancestor counts". The blanket version classified
  # every broadly inherited base class (ApplicationJob via two seams, BaseActor
  # via CreateAiPost), and a for_feature helper planted there would have passed
  # every guard: Guard A only watches the raw lanes, and Guard B saw the file as
  # classified (adversarial R5 review, MAJOR 2 — the plausible trigger is an
  # innocent "pull the routing helper up into the base class" refactor). With
  # the list, such a file is unclassified again and fails the completeness
  # check. Entries have their own honesty test below.
  # `calls:` for the same reason as on the two allowlists: this list attributes a
  # file's routing to seams that inherit it, and ONE inherited line is exactly
  # what the reasons below claim. A second line here would be attributed to the
  # same seams without anyone saying so — and if its key comes from a method
  # rather than a literal, no pattern sees which row it took.
  seam_routing_ancestors = {
    'app/services/meetings/base_llm_service.rb' => {
      calls: 1,
      reason: 'the three meetings seams route through ONE inherited line here (each subclass declares ' \
              'its #feature_key) — the whole point of that hierarchy'
    },
    'app/services/lalabase/indexer/job_support.rb' => {
      calls: 1,
      reason: 'embedding half of the ProjectIndexerJob seam, mixed in as a module — the chat half ' \
              'routes in the job file itself'
    }
  }.freeze

  # A constant that vanished must fail ONE example with a built message (the
  # "real constant" check), not three with raw NameErrors — hence const_defined?
  # guards here (R5 review, diagnostics finding).
  #
  # The const_get looks redundant and is not: const_defined? sees a PENDING
  # Zeitwerk autoload without triggering it, and const_source_location on a
  # pending autoload names zeitwerk/cref.rb, not the seam's file — every
  # not-yet-loaded seam would count as non-routing (found the hard way in this
  # very spec: the already-booted jobs passed, the lazy-loaded services failed).
  own_source_file_of = lambda do |constant_name|
    next nil unless Object.const_defined?(constant_name)

    Object.const_get(constant_name)
    path, = Object.const_source_location(constant_name)
    path ? relative_of.call(path) : nil
  end

  ancestor_source_files_of = lambda do |constant_name|
    next [] unless Object.const_defined?(constant_name)

    klass = Object.const_get(constant_name)
    app_root = Rails.root.join('app').to_s
    klass.ancestors.filter_map do |mod|
      name = mod.respond_to?(:name) ? mod.name : nil
      next unless name

      path, = Object.const_source_location(name)
      next unless path&.start_with?(app_root)

      relative_of.call(path)
    end.uniq
  end

  # A seam's routing files: its own source plus those of its ancestors that are
  # EXPLICITLY listed above.
  routing_files_of = lambda do |constant_name|
    own = own_source_file_of.call(constant_name)
    listed = ancestor_source_files_of.call(constant_name) & seam_routing_ancestors.keys
    ([own] + listed).compact.uniq
  end

  describe 'Guard A — the raw lanes (for_chat / for_embeddings)' do
    it 'for_chat is called only in the allowlisted files' do
      offenders = offenders_for.call(chat_lane_call, chat_lane_callers, scanned_sources, code_of)

      expect(offenders).to be_empty, <<~MSG
        Factory.for_chat called outside the allowlist:
        #{offenders.join("\n")}

        for_chat resolves featurelessly — the gate that guards your surface and the
        route your request takes stop reading the same registry row, which is the
        drift the registry exists to end. Declare (or reuse) a row in
        Lalabase::Llm::FeatureRegistry and route through
        Factory.for_feature(:your_key, organisation). If the path genuinely is no
        feature (diagnostics, ops tooling), add it to this guard's allowlist AND to
        FeatureRegistry::EXCLUDED_CALLERS — with the reason.
      MSG
    end

    it 'for_embeddings is called only in the allowlisted files' do
      offenders = offenders_for.call(embedding_lane_call, embedding_lane_callers, scanned_sources, code_of)

      expect(offenders).to be_empty, <<~MSG
        Factory.for_embeddings called outside the allowlist:
        #{offenders.join("\n")}

        Same contract as for_chat (see the message there), embedding edition — and
        remember §7.1: never answer an embedding question from chat columns. Route
        through Factory.for_feature(key, org, space: ...) or argue your entry.
      MSG
    end

    it 'each allowlisted file still exists and calls its lane exactly as often as declared' do
      expect(actual_calls.call(chat_lane_call, chat_lane_callers, code_of))
        .to eq(expected_calls.call(chat_lane_callers)),
            'chat lane: a 0 means the entry went stale (drop it), a higher number means the file ' \
            'grew another raw-lane call — route it via for_feature, or raise calls: and say why here'
      expect(actual_calls.call(embedding_lane_call, embedding_lane_callers, code_of))
        .to eq(expected_calls.call(embedding_lane_callers)),
            'embedding lane: same contract as chat above'
    end
  end

  describe 'Guard B — registry rows and factory callers map onto each other' do
    it 'gives every entry a unique seam (one row, one routing decision)' do
      seams = registry.all.map(&:seam)
      expect(seams).to match_array(seams.uniq),
                       "Duplicate seam entries: #{seams.tally.select { |_, n| n > 1 }.keys.join(', ')}"
    end

    it 'resolves every seam: to a real constant' do
      missing = registry.all.reject { |feature| Object.const_defined?(feature.seam) }

      expect(missing).to be_empty, <<~MSG
        Registry rows whose seam: names no existing constant:
        #{missing.map { |f| "#{f.key}: #{f.seam}" }.join("\n")}

        A row whose seam is gone gates a feature that cannot run — either the seam
        was renamed (update the row) or the feature is dead (delete the row).
      MSG
    end

    it 'has every seam actually routing through the factory (dead-entry killer)' do
      dead = registry.all.reject do |feature|
        routing_files_of.call(feature.seam).any? do |relative|
          code_of.call(Rails.root.join(relative).to_s).match?(factory_route_call)
        end
      end

      expect(dead).to be_empty, <<~MSG
        Registry rows whose seam never calls the factory:
        #{dead.map { |f| "#{f.key}: #{f.seam}" }.join("\n")}

        The gate answers "may I offer this?" as "would the ROUTING succeed" — for a
        seam that does not route, that answer is fiction. Either the seam stopped
        being the place where this feature builds its provider (point the row at the
        real one) or the feature is dead (delete the row).
      MSG
    end

    it 'classifies every file that routes through the factory (seam, listed ancestor, or excluded with a reason)' do
      classified = registry.all.flat_map { |feature| routing_files_of.call(feature.seam) }.to_set
      classified << factory_path

      offenders = scanned_sources.call.reject { |path| File.symlink?(path) }.filter_map do |path|
        relative = relative_of.call(path)
        next if classified.include?(relative)
        next if registry::EXCLUDED_CALLERS.key?(relative)

        relative if code_of.call(path).match?(factory_route_call)
      end

      expect(offenders).to be_empty, <<~MSG
        Files that route through the factory but are neither a registered seam nor excluded:
        #{offenders.join("\n")}

        Classify each one: give it a FeatureRegistry row (seam:) so gate and route
        read the same line — or add it to FeatureRegistry::EXCLUDED_CALLERS with the
        reason it is no feature. A routing file the registry does not know about is
        an AI path without a gate truth (plan §5.3 Guard B).
      MSG
    end

    # Everything above asks WHETHER a seam routes. These two ask WHICH ROW it
    # routes on — the question the guard was missing (cross-model review,
    # 2026-08-03): a meetings subclass returning :meeting_summary from
    # #feature_key while its registry row says :meeting_analysis passed every
    # example, gate and route reading two different lines. That IS the drift R5
    # exists to end, so "some factory call is present" is not enough.
    #
    # A seam names its key one of two ways, and both are covered: a literal at
    # the call site (nine seams since R6), or a #feature_key that the INHERITED
    # call site in Meetings::BaseLlmService reads (the three meetings
    # subclasses, where the key is a variable and no pattern can see it).
    it 'lets a file name only the feature keys whose rows it owns (literal call sites)' do
      offenders = scanned_sources.call.reject { |path| File.symlink?(path) }.flat_map do |path|
        relative = relative_of.call(path)
        code_of.call(path).scan(feature_key_literal).flatten.uniq.filter_map do |key|
          feature = registry::BY_KEY[key.to_sym]
          next "#{relative}: for_feature(:#{key}) — no registry row has that key" if feature.nil?
          next if routing_files_of.call(feature.seam).include?(relative)

          "#{relative}: for_feature(:#{key}) — that row's seam is #{feature.seam}"
        end
      end

      expect(offenders).to be_empty, <<~MSG
        Feature keys routed from a file that does not own their row:
        #{offenders.join("\n")}

        The gate asks ai_available_for?(:key) and the route asks
        for_feature(:key) — they only read the SAME line while the key is the
        same. A file routing a key whose seam: points elsewhere means one of the
        two is now answering about a different feature. Route your own key, or
        move the seam: to this file.
      MSG
    end

    it 'has every seam that supplies its key at runtime declare exactly its own key' do
      offenders = registry.all.filter_map do |feature|
        next unless Object.const_defined?(feature.seam)

        klass = Object.const_get(feature.seam)
        own_file = own_source_file_of.call(feature.seam)
        routes_itself = own_file && code_of.call(Rails.root.join(own_file).to_s).match?(factory_route_call)
        declares = klass.is_a?(Class) &&
                   (klass.method_defined?(:feature_key) || klass.private_method_defined?(:feature_key))

        # Routing in a listed ancestor with a key this class supplies: then
        # #feature_key is the ONLY thing tying the row to the route, so its
        # absence is the same hole as a wrong value.
        next "#{feature.key}: #{feature.seam} routes only through an ancestor and declares no #feature_key" unless routes_itself || declares
        next unless declares

        # allocate, not new: every implementation returns a literal, and the
        # seams take constructor arguments a guard has no business inventing.
        # A subclass that dropped its override inherits BaseLlmService's raiser —
        # caught here as a finding rather than as an error out of the example.
        declared = begin
          klass.allocate.send(:feature_key)
        rescue NotImplementedError
          nil
        end
        next "#{feature.key}: #{feature.seam} inherits the abstract #feature_key without implementing it" if declared.nil?
        next if declared == feature.key

        "#{feature.key}: #{feature.seam}#feature_key returns #{declared.inspect}"
      end

      expect(offenders).to be_empty, <<~MSG
        Seams whose declared feature key disagrees with their registry row:
        #{offenders.join("\n")}

        Meetings::BaseLlmService routes on whatever #feature_key returns, while
        the surface gates on the row that names this class as its seam. When the
        two differ, an org can be shown a button for one feature and billed,
        pinned and routed on another — silently, because both halves work.
      MSG
    end

    it 'keeps the routing-ancestor list honest: entries exist, route exactly as declared, and ARE ancestors of a seam' do
      registered = registry.all.map(&:seam)

      seam_routing_ancestors.each do |relative, entry|
        path = Rails.root.join(relative)
        expect(File.exist?(path)).to be(true),
                                     "seam_routing_ancestors entry #{relative} no longer exists — drop it"
        expect(code_of.call(path.to_s).scan(factory_route_call).size).to eq(entry.fetch(:calls)),
                                                                         "seam_routing_ancestors #{relative} " \
                                                                         "declares #{entry.fetch(:calls)} routing " \
                                                                         'call(s). 0 means drop the entry; more ' \
                                                                         'means a second inherited route the ' \
                                                                         'listed seams now silently share'
        expect(entry[:reason]).to be_present, "seam_routing_ancestors #{relative} has no reason"

        covers = registered.any? { |seam| ancestor_source_files_of.call(seam).include?(relative) }
        expect(covers).to be(true),
                          "#{relative} is no ancestor of any registered seam — a listed file nothing " \
                          'inherits from is a free pass, not an exception'
      end
    end

    it 'keeps EXCLUDED_CALLERS honest: entries exist, route exactly as declared, carry a reason, and are no seams' do
      seam_files = registry.all.flat_map { |feature| routing_files_of.call(feature.seam) }.to_set

      registry::EXCLUDED_CALLERS.each do |relative, entry|
        path = Rails.root.join(relative)
        expect(File.exist?(path)).to be(true),
                                     "EXCLUDED_CALLERS entry #{relative} no longer exists — drop it"
        # The COUNT, not just presence: an exemption excuses a FILE, so without a
        # number a second routing call rides in on the first one's reason.
        expect(code_of.call(path.to_s).scan(factory_route_call).size).to eq(entry.fetch(:calls)),
                                                                         "EXCLUDED_CALLERS #{relative} declares " \
                                                                         "#{entry.fetch(:calls)} routing call(s). " \
                                                                         '0 means the entry is stale (drop it); ' \
                                                                         'more means the file grew a route — give ' \
                                                                         'it a registry row, or raise calls: here ' \
                                                                         'with the reason'
        expect(entry[:reason]).to be_present, "EXCLUDED_CALLERS #{relative} has no reason"
        expect(seam_files).not_to include(relative),
                                  "#{relative} is both a registered seam (file) and excluded — decide"
      end
    end

    it 'keeps every ungated resolution real, reasoned and out of the registry (§7.5)' do
      registry::UNGATED_RESOLUTIONS.each do |qualified, reason|
        expect(reason).to be_present, "UNGATED_RESOLUTIONS #{qualified} has no reason"

        # const_defined? first, for the same reason as the seam checks above: a
        # renamed Factory must fail with the message that says what to do, not
        # with a raw NameError out of const_get.
        const_name, _sep, method_name = qualified.rpartition('.')
        expect(Object.const_defined?(const_name)).to be(true),
                                                     "UNGATED_RESOLUTIONS entry #{qualified}: #{const_name} is gone — " \
                                                     'drop or rename it'
        expect(Object.const_get(const_name)).to respond_to(method_name),
                                                "UNGATED_RESOLUTIONS entry #{qualified} does not exist any more — " \
                                                'drop or rename it'
        # No "seam: never names this" check here: a seam: is a CONSTANT name and
        # this key is a method reference (with a dot), so the two value ranges
        # cannot intersect — such an expectation could never fail and would read
        # like a fence while being none. What §7.5 actually needs is the
        # have_key below, and that one bites.
      end

      # §7.5 verbatim: the completeness guard must carry embedding_space_for
      # EXPLICITLY — deleting the entry has to turn this red, not stay quiet.
      expect(registry::UNGATED_RESOLUTIONS)
        .to have_key('Lalabase::Llm::Factory.embedding_space_for')
    end
  end

  describe 'Guard C — surfaces do not talk to the low-level predicates' do
    it 'no view/controller/helper/component calls ai_available? or has_valid_*_configuration?' do
      offenders = offenders_for.call(low_level_predicate, surface_predicate_callers,
                                     scanned_surfaces, surface_code_of)

      expect(offenders).to be_empty, <<~MSG
        Low-level AI predicates called from a surface:
        #{offenders.join("\n")}

        ai_available? and has_valid_*_configuration? are Organisation's INTERNAL API
        (plan E3) — they answer about a provider name and cannot say why, so every
        surface built on them re-derives the gate the registry already owns. Ask
        organisation.ai_available_for?(:feature_key) — its Availability carries
        available?/reason/required_provider/lane, and
        FeatureRegistry.unavailable_hint(availability, org) is the one source for the
        refusal copy. (ai_enabled? stays fine: the opt-in question belongs to surfaces.)
      MSG
    end

    it 'keeps the allowlist empty (E3: it ends empty at R5 — an entry is a plan change, not a formality)' do
      expect(surface_predicate_callers).to be_empty
    end

    # Strictly wider than the example above, which stays for its own sake: E3 is
    # a promise about SURFACES, and a promise needs an example that names it and
    # an allowlist that visibly stays empty. This one adds the layers the plan
    # did not think to name, where the allowlist cannot be empty — and where the
    # two entries carry the argument for the fence rather than an exception to it.
    it 'lets no other production file re-derive the gate either (owners only)' do
      offenders = offenders_for.call(low_level_predicate, low_level_owners, scanned_sources, code_of)

      expect(offenders).to be_empty, <<~MSG
        Low-level AI predicates called outside their two owners:
        #{offenders.join("\n")}

        A job or service asking has_valid_ai_configuration? re-derives the gate
        the registry already owns — the same drift as on a surface, only without
        anyone watching. Ask Factory.for_feature(:key, org) if you need the
        provider, organisation.ai_available_for?(:key) if you need the answer.
        If you are genuinely building a second resolution, that is a plan change
        (§5.3 point 1), not an allowlist entry.
      MSG
    end
  end

  # The pattern is the part of a grep guard that fails SILENTLY: too narrow and
  # every test above stays green while covering nothing (§7.2 — the literal-based
  # inventory this plan replaces missed three of eight pins exactly that way).
  describe 'the search patterns themselves' do
    it 'match qualified, multi-line and safe-navigation lane calls' do
      expect('Lalabase::Llm::Factory.for_chat(organisation)').to match(chat_lane_call)
      expect("Lalabase::Llm::Factory\n        .for_chat(organisation)").to match(chat_lane_call)
      expect('Llm::Factory&.for_chat(org)').to match(chat_lane_call)
      expect('Lalabase::Llm::Factory.for_embeddings(org, space: :configured)').to match(embedding_lane_call)
      expect("Factory\n  .for_embeddings(organisation, space: :active)").to match(embedding_lane_call)
    end

    it 'does not mistake for_feature or unrelated factories for a raw lane' do
      expect('Lalabase::Llm::Factory.for_feature(:chat, org)').not_to match(chat_lane_call)
      expect('Lalabase::Llm::Factory.for_feature(:content_indexing, org, space: :configured)')
        .not_to match(embedding_lane_call)
      expect('SmartFolderRuleFactory.for_chat(whatever)').not_to match(chat_lane_call)
    end

    it 'leaves the factory internals alone (bare calls carry no Factory receiver)' do
      # This is WHY factory.rb needs no allowlist entry — and why a qualified
      # call may not appear anywhere, the factory included. Known flip side
      # (R5 review): `include Lalabase::Llm::Factory` plus a bare call would ride
      # this exemption — that is the accepted grep-guard bypass class (alias
      # constants, send, const_get live there too); no pattern stops the
      # determined, same trade-off provider_pin_guard documents.
      expect('provider = for_chat(organisation)').not_to match(chat_lane_call)
      expect('for_embeddings(organisation, space: space)').not_to match(embedding_lane_call)
    end

    it 'does not mistake the ungated space resolution for the embedding lane (§7.5)' do
      expect('Lalabase::Llm::Factory.embedding_space_for(org, space: :active)')
        .not_to match(embedding_lane_call)
      expect('Lalabase::Llm::Factory.embedding_space_for(org, space: :active)')
        .not_to match(factory_route_call)
    end

    it 'sees the :: call form, which is legal Ruby and had no call site to warn us' do
      expect('Lalabase::Llm::Factory::for_chat(organisation)').to match(chat_lane_call)
      expect('Lalabase::Llm::Factory::for_embeddings(org, space: :configured)').to match(embedding_lane_call)
      expect('Lalabase::Llm::Factory::for_feature(:chat, org)').to match(factory_route_call)
      # The constant lookup that shares the syntax must stay out.
      expect('Lalabase::Llm::Factory::PROVIDER_CLASSES').not_to match(factory_route_call)
    end

    it 'reads the literal key out of a call site, and only a literal one' do
      expect('Lalabase::Llm::Factory.for_feature(:ticket_summary, org)'.scan(feature_key_literal).flatten)
        .to eq(['ticket_summary'])
      expect("Factory\n  .for_feature(\n    :repository_indexing, org, lane: :chat)".scan(feature_key_literal).flatten)
        .to eq(['repository_indexing'])
      # The inherited meetings call site passes a METHOD — invisible here by
      # design, which is why the #feature_key example exists.
      expect('Lalabase::Llm::Factory.for_feature(feature_key, organisation)'.scan(feature_key_literal)).to be_empty
      # `lane:` is not the key: only the FIRST argument counts.
      expect('Lalabase::Llm::Factory.for_chat(org)'.scan(feature_key_literal)).to be_empty
    end

    it 'the route pattern sees all three ways to route' do
      expect('Lalabase::Llm::Factory.for_feature(:ticket_summary, organisation)').to match(factory_route_call)
      expect('Lalabase::Llm::Factory.for_chat(organisation)').to match(factory_route_call)
      expect("Lalabase::Llm::Factory\n  .for_embeddings(org, space: :configured)").to match(factory_route_call)
    end

    it 'matches every low-level predicate with any receiver form' do
      expect("organisation.ai_available?('openai')").to match(low_level_predicate)
      expect('org&.ai_available?(provider)').to match(low_level_predicate)
      expect('current_organisation.has_valid_ai_configuration?(provider)').to match(low_level_predicate)
      expect('org.has_valid_embedding_configuration?(name)').to match(low_level_predicate)
    end

    it 'leaves the feature-keyed gate, the opt-in and the renamed controller helper alone' do
      expect('organisation.ai_available_for?(:chat)').not_to match(low_level_predicate)
      expect('org&.ai_available_for?(:content_indexing)&.available?').not_to match(low_level_predicate)
      expect('@current_organisation&.ai_enabled?').not_to match(low_level_predicate)
      expect('return respond_hint(key) unless ai_feature_available?').not_to match(low_level_predicate)
    end

    it 'strips ERB comment blocks but keeps live ERB code (surface reader self-test)' do
      Tempfile.create(['guard_selftest', '.erb']) do |file|
        file.write(<<~ERB)
          <%# history note: this used to call ai_available?('openai')
              across two lines %>
          <% ok = org.ai_available_for?(:chat) %>
        ERB
        file.flush
        expect(surface_code_of.call(file.path)).not_to match(low_level_predicate)
      end

      Tempfile.create(['guard_selftest_live', '.erb']) do |file|
        file.write("<% gate = org.ai_available?('openai') %>\n")
        file.flush
        expect(surface_code_of.call(file.path)).to match(low_level_predicate)
      end
    end

    it 'scans a non-empty tree (self-test against dead globs)' do
      sources = scanned_sources.call.map { |path| relative_of.call(path) }
      expect(sources).to include(factory_path)
      # The rake glob earns its own witness: lib/**/*.rb matches nothing today
      # (lib/ holds assets and tasks only), so a typo there cannot be
      # caught this way — the .rake witness at least pins the tasks tree.
      expect(sources).to include('lib/tasks/embeddings.rake')
      surfaces = scanned_surfaces.call.map { |path| relative_of.call(path) }
      expect(surfaces).to include('app/controllers/organisations/meeting_analyses_controller.rb')
      expect(surfaces).to include('app/policies/ai_settings_policy.rb')
      expect(surfaces.any? { |path| path.end_with?('.erb') }).to be(true)
    end
  end
end

# frozen_string_literal: true

# What: Guard spec — a code path may only pin its chat provider if it is on the
#   allowlist below. Every other path follows the organisation's choice via
#   Lalabase::Llm::Factory.for_chat.
# Why (philosophy): The org's provider choice is a GDPR statement, not a
#   preference — it decides which jurisdiction sees the data. A pinned path
#   silently overrides that choice: an org that switched to Vertex/europe-west3
#   still had its meeting transcripts sent to OpenAI, and nothing in the UI said
#   so. Of the eight paths the plan's inventory (§2.1) found, seven now follow the
#   org — P1/P2 in S1, P6–P8 in S1b, P3/P4 in S2 (doc/ki_provider_reichweite_plan.md) —
#   and the eighth (P5) no longer pins HERE: R3 moved it into the feature registry,
#   where the gate reads the same row (doc/ai_feature_registry_plan.md). Nothing but
#   this guard stops the next Factory refactor from reintroducing one as
#   "behaviour-preserving" — which is exactly how P4 and the meetings services came
#   to exist in the first place.
# Contract: the chat provider is chosen by the ORG, except in the allowlisted
#   files below — across all three ways to make that choice yourself.
#
# NOT covered here (deliberate): the MODEL a path pins. Provider is the
# jurisdiction axis (AVV-relevant, rare, forces a reindex when embeddings move);
# model is the performance axis (cost only). Mixing them into one guard would
# blur the axis that carries the legal weight. The five-fold gpt-4o-mini constant
# that motivated this note is gone as of S2 — the literal survives in app/ only
# where it belongs, as OpenAiProvider::DEFAULT_CHAT_MODEL.
#
# Also deliberate: this is a GREP guard, not an AST scanner. It fences off the
# accidental 1:1 carry-over during the next Factory refactor — the way every
# pin here actually came to exist. It does not pretend to stop someone who
# assigns `F = Lalabase::Llm::Factory` to get around it; no pattern would.

require 'rails_helper'

RSpec.describe 'LLM chat provider pin guard' do
  # THREE ways to choose the provider yourself, in descending order of how much
  # of the seam they skip. Each needs its own pattern — a path that takes door 2
  # or 3 is invisible to door 1's pattern, and vice versa.
  #
  # Door 1 — Factory.build: uses the seam (gates, credentials, quota all apply)
  #   but overrides WHICH provider.
  # Door 2 — PROVIDER_CLASSES: the registry maps name -> class, so looking one up
  #   and instantiating it skips the whole seam.
  # Door 3 — the provider class by name: Provider#initialize needs nothing but
  #   api_key:, so `Lalabase::Llm::OpenAiProvider.new(api_key: ...)` is trivial to
  #   write and skips the seam just as completely.
  #
  # Doors 2 and 3 are unused today. They are guarded anyway, for the same reason
  # the fence exists at all: the pins that had to be removed in S1–S4 were not
  # written maliciously, they were written as the obvious next line.
  #
  # `\s*&?\.\s*` in every pattern: RuboCop breaks long chains across lines
  # (`Factory\n  .build(...)`), and the existing call sites are already near the
  # line limit. A pattern that only sees the single-line form would go quietly
  # blind the first time someone nests a call one level deeper.
  pin_call = /(?<![A-Za-z0-9_])Factory\s*&?\.\s*build\b/
  registry_pattern = /(?<![A-Za-z0-9_])PROVIDER_CLASSES\b/
  provider_class_call = /(?<![A-Za-z0-9_])\w*Provider\s*&?\.\s*new\b/

  # Matching the CALL, never the VALUE, is the point of door 1's pattern:
  # Factory.build REQUIRES provider_name:, so calling it IS pinning — whether the
  # provider arrives as a literal ('openai'), a constant (PROVIDER_NAME) or a
  # variable.
  #
  # This wording is the correction of a concrete miss: the inventory in
  # doc/ki_provider_reichweite_plan.md §2.1 searched for `provider_name: 'openai'`
  # WITH the literal and reported five pinned paths where there were eight —
  # three handed the provider in through a constant and stayed invisible. A
  # literal-based guard would be green and worthless. The lookbehind keeps
  # unrelated builders whose class name merely ENDS in Factory
  # (SmartFolderRuleFactory) out, without needing to know their names.
  #
  # SHRINK-ONLY, and as of R3 it has shrunk to EMPTY — the honest state, the same
  # one door 3 has always been in.
  #
  # The last entry was P5 (customer_description_generator.rb). Its pin did not go
  # away; it MOVED, from a constant in the service to one line in
  # Lalabase::Llm::FeatureRegistry, and the service now calls
  # Factory.for_feature(:customer_description, org). That is a strictly better place
  # for it than an allowlist entry: the gate reads the same row, so a pin can no
  # longer exist without the refusal that has to accompany it.
  #
  # Which is why this guard stays interesting rather than becoming decoration: the
  # seam's own `build(provider_name: feature.pin, ...)` is a BARE call inside
  # factory.rb and does not match door 1's pattern, so nothing in app/ or lib/ may
  # name Factory.build any more. A new pin has to argue for itself in the registry,
  # in public, next to its pin_reason.
  pinned_call_sites = {}.freeze

  # Door 2 readers. Allowlisted are the paths where NO organisation data flows:
  # the seam that owns the registry, plus credential-side code that asks it about
  # a provider rather than routing through one.
  registry_readers = {
    'app/services/lalabase/llm/factory.rb' =>
      'owns it — every org data path goes through here BY DESIGN; that is the seam',
    'app/models/concerns/ai_credential_connectivity.rb' =>
      'admin connection probe — builds a provider from ONE credential under test, never for ' \
      'an org data path',
    'app/models/concerns/ai_credential_provider_rules.rb' =>
      'metadata only — reads .keys and #supports_embeddings? for validation, builds nothing'
  }.freeze

  # Door 3 has NO legitimate caller: even the Factory builds through the registry
  # variable (`klass.new`), never through a class name. An empty allowlist is the
  # honest state — if this ever needs an entry, that is a design conversation,
  # not a formality.
  #
  # The pattern is deliberately generic (\w*Provider.new), so a FIFTH provider
  # class is covered the day it is written. Cost of that breadth: a future
  # unrelated `SomethingProvider` elsewhere in app/ would trip this guard. That
  # is the failure direction we want — loud and once, not silent and forever.
  provider_class_builders = {}.freeze

  # Whole comment lines do not route anything, and filtering them matters in both
  # directions: an allowlisted file whose pin decays into a comment must not stay
  # green (that is how a guard rots), and a file that merely NAMES the pattern in
  # prose must not need an allowlist entry (which would then hide a real call in
  # it). Trailing comments (`x = 1 # Factory.build(y)`) are NOT stripped — doing
  # that by regex would misfire on '#' inside strings. Consequence: a trailing
  # comment mentioning a pattern raises a false alarm. Loud and rare beats
  # silent, and it has never happened.
  code_of = lambda do |path|
    File.readlines(path).reject { |line| line.lstrip.start_with?('#') }.join
  end

  # .rake is in the glob on purpose: a backfill/reindex task is the single most
  # likely birthplace of a NEW pin (it is the shape GenerateGroupCustomerDescriptions
  # could have taken), and lib/tasks holds 35 files that `*.rb` does not see.
  scanned = lambda do
    Dir.glob([Rails.root.join('app/**/*.rb'),
              Rails.root.join('lib/**/*.rb'),
              Rails.root.join('lib/tasks/**/*.rake')])
  end

  # Shared shape for all three doors: offenders outside the allowlist, plus a
  # self-test that every allowlist entry still exists AND still matches. Without
  # the second half a guard shrinks silently — a renamed file or a pin that moved
  # onto for_chat leaves a dead entry while the first test keeps passing over
  # less and less. Red there means "delete the entry", and that is precisely the
  # shrink-only mechanism that keeps the allowlist an honest inventory.
  offenders_for = lambda do |pattern, allowlist|
    scanned.call.reject { |path| File.symlink?(path) }.select do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next false if allowlist.key?(relative)

      code_of.call(path).match?(pattern)
    end
  end

  still_matching = lambda do |pattern, allowlist|
    allowlist.keys.select do |relative|
      path = Rails.root.join(relative)
      File.exist?(path) && code_of.call(path).match?(pattern)
    end
  end

  describe 'door 1 — Factory.build (seam used, provider overridden)' do
    it 'is opened only in the allowlisted files' do
      offenders = offenders_for.call(pin_call, pinned_call_sites)

      expect(offenders).to be_empty, <<~MSG
        Chat provider pinned outside the allowlist:
        #{offenders.join("\n")}

        Factory.build(provider_name: ...) overrides the organisation's provider choice —
        the choice that decides which jurisdiction sees the data. Use
        Lalabase::Llm::Factory.for_chat(organisation) instead.

        If the path genuinely CANNOT follow the org (a provider-specific model dialect,
        as with :customer_description), the pin does NOT belong here any more: declare it
        in Lalabase::Llm::FeatureRegistry (pin: + pin_reason:) and route through
        Factory.for_feature(key, org). That way the gate reads the same row, so orgs
        routing elsewhere see an honest "unavailable" instead of having their data sent
        to the pinned provider anyway — the refusal cannot be forgotten because it is
        not a second edit.
      MSG
    end

    it 'each allowlisted file still exists and still pins (must not go stale)' do
      expect(still_matching.call(pin_call, pinned_call_sites)).to match_array(pinned_call_sites.keys)
    end
  end

  describe 'door 2 — PROVIDER_CLASSES (registry looked up directly)' do
    it 'is read only where no organisation data flows' do
      offenders = offenders_for.call(registry_pattern, registry_readers)

      expect(offenders).to be_empty, <<~MSG
        Direct PROVIDER_CLASSES access outside the allowlist:
        #{offenders.join("\n")}

        Looking a provider class up by name and instantiating it bypasses the whole
        seam — credential resolution, the ai_enabled gate and the quota gate all live
        in Lalabase::Llm::Factory. Route through for_chat / for_embeddings.
      MSG
    end

    it 'each allowlisted reader still exists and still reads (must not go stale)' do
      expect(still_matching.call(registry_pattern, registry_readers)).to match_array(registry_readers.keys)
    end
  end

  describe 'door 3 — the provider class by name' do
    it 'is never opened' do
      offenders = offenders_for.call(provider_class_call, provider_class_builders)

      expect(offenders).to be_empty, <<~MSG
        A provider class is instantiated directly:
        #{offenders.join("\n")}

        Provider#initialize takes api_key: and nothing else is required, which makes this
        the easiest way to skip EVERYTHING: the org's provider choice, the ai_enabled
        opt-in gate, the quota gate and BYOK credential resolution. Even the Factory does
        not do this — it builds through the registry (klass.new).

        Route through Lalabase::Llm::Factory.for_chat / .for_embeddings.
      MSG
    end
  end

  # The pattern is the part of a grep guard that fails SILENTLY: too narrow and
  # every test above stays green while covering nothing. Pinning its behaviour is
  # therefore not paranoia — a too-narrow pattern is precisely what produced the
  # incomplete inventory this guard exists to prevent.
  describe 'the search patterns themselves' do
    it 'match a literal, a constant and a variable alike (door 1)' do
      expect("Lalabase::Llm::Factory.build(provider_name: 'openai', organisation: org)").to match(pin_call)
      expect('Lalabase::Llm::Factory.build(provider_name: PROVIDER_NAME, organisation: org)').to match(pin_call)
      expect('Llm::Factory.build(provider_name: name, organisation: org)').to match(pin_call)
    end

    it 'match regardless of keyword order (door 1)' do
      expect('Llm::Factory.build(organisation: org, provider_name: name)').to match(pin_call)
    end

    it 'match the multi-line chain RuboCop produces for long calls (door 1)' do
      expect("Lalabase::Llm::Factory\n        .build(provider_name: PROVIDER_NAME, organisation: org)").to match(pin_call)
    end

    it 'match the safe-navigation form (door 1)' do
      expect('Llm::Factory&.build(provider_name: name, organisation: org)').to match(pin_call)
    end

    it 'ignore unrelated builders whose class name ends in Factory (door 1)' do
      expect("SmartFolderRuleFactory.build(group, 'assignee', 'equals', id, 1)").not_to match(pin_call)
    end

    it 'leave the ungated seams alone (door 1)' do
      expect('Lalabase::Llm::Factory.for_chat(organisation)').not_to match(pin_call)
      expect('Lalabase::Llm::Factory.for_embeddings(organisation)').not_to match(pin_call)
    end

    it 'match every provider class, qualified or not, including one not yet written (door 3)' do
      expect('Lalabase::Llm::OpenAiProvider.new(api_key: key)').to match(provider_class_call)
      expect('AnthropicProvider.new(api_key: key)').to match(provider_class_call)
      expect('GoogleVertexProvider.new(api_key: key)').to match(provider_class_call)
      expect('Provider.new(api_key: key)').to match(provider_class_call)
      expect('MistralEuProvider.new(api_key: key)').to match(provider_class_call)
    end

    it 'leave the registry-based construction the Factory itself uses alone (door 3)' do
      # `klass.new(...)` is HOW the seam builds providers — matching it would make
      # the guard unable to distinguish the seam from a bypass.
      expect('klass.new(api_key: creds[:api_key], organisation: organisation)').not_to match(provider_class_call)
    end

    it 'does not fire on a mere mention of the registry constant (door 2)' do
      expect('PROVIDER_CLASSES_BACKUP.fetch(name)').not_to match(registry_pattern)
    end
  end
end

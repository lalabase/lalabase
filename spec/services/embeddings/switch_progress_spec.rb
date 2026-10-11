# frozen_string_literal: true

# What: Embeddings::SwitchProgress — the state and the two numbers behind the P4c
#   progress notice in the customer's AI settings (plan E1).
# Type: Service spec, real queries against the embedded tables.
# Why (philosophy): this notice is the only thing on the page that says whether a
#   paid, hours-long re-embedding is moving, finished, or stopped. Every example
#   below pins a state the customer would otherwise MISREAD: a paused run that looks
#   like a slow one, a finished one that looks like it is still going, and above all
#   the pointer-less org, where the class is structurally blind and silence would
#   look identical to "nothing is happening" while search returns nothing at all.
# Contract: :none unless a staged switch is pending; :pointer_missing takes
#   precedence over every measurement; among the measured states the FLIP is decided
#   before the quota, mirroring Embeddings::SwitchWatcherJob's own order.

require 'rails_helper'

RSpec.describe Embeddings::SwitchProgress do
  let(:organisation) { create(:organisation) }

  # The org's configured lane: openai / text-embedding-3-small / 1536. Everything
  # below is expressed as agreement or disagreement with THIS triple.
  let!(:system_credential) do
    create(:ai_credential, provider: 'openai', active: true, enabled: true)
  end

  # A pointer at a DIFFERENT triple — which is what a staged switch IS: the org
  # serves from the old space while the configured one is being built.
  def point_at(model: 'text-embedding-3-large', dims: 3072)
    space = ActsAsTenant.with_tenant(organisation) do
      create(:embedding_space, organisation: organisation,
                               embedding_model: model, embedding_dims: dims)
    end
    organisation.update_column(:active_embedding_space_id, space.id)
    space
  end

  # One source record in a table the reindexer walks.
  def record(signature: 'a' * 40)
    ActsAsTenant.with_tenant(organisation) do
      create(:code_symbol, organisation: organisation, signature: signature)
    end
  end

  # A readable row for `symbol` in the CONFIGURED (target) triple — i.e. one record
  # the rebuild has already done. The factory's defaults are that triple.
  def embed_into_target(symbol)
    ActsAsTenant.with_tenant(organisation) do
      create(:content_embedding, embeddable: symbol, organisation: organisation, indexed: true)
    end
  end

  # A curated package whose embedding credential is METERED and deliberately NOT the
  # provider's `active` row — the shape that tells a credential lookup from a name
  # lookup. Region and domicile come from the jurisdiction MATRIX because AiPackage
  # validates the declared rung against the pair it derives from the credentials, and
  # the full ladder because a published package must offer every rung.
  def metered_package
    domicile_eu, region_eu = AiPackage::JURISDICTION_MATRIX.key('eu_native')
    credential = create(:ai_credential, provider: 'openai', active: false, enabled: true,
                                        included_in_quota: true,
                                        region: region_eu ? 'eu' : 'us',
                                        company_domicile: domicile_eu ? 'eu' : 'non_eu')
    package = build(:ai_package, name: 'Metered', jurisdiction: 'eu_native', active: true,
                                 embedding_credential: credential,
                                 embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                               chat_credential: credential, position: index)
    end
    package.save!
    package
  end

  describe 'when no staged switch is pending' do
    it 'says nothing for an org whose pointer names its configured space' do
      point_at(model: 'text-embedding-3-small', dims: 1536)
      record

      result = described_class.call(organisation: organisation)

      expect(result.state).to eq(:none)
      expect(result).not_to be_in_progress
    end

    # The AI opt-in is the org's GDPR switch and defaults to false. With it off
    # Actors::SelectAiPackage enqueues nothing, so there is no rebuild to report —
    # and this branch is also what keeps the four anti-joins off the page for every
    # org that never turned AI on.
    it 'says nothing for an org with the AI opt-in off' do
      point_at
      organisation.update_column(:ai_enabled, false)

      expect(described_class.call(organisation: organisation).state).to eq(:none)
    end
  end

  # The state this class cannot see — and, since the P4c review, deliberately does
  # not guess at.
  #
  # Factory#embedding_space_for(:active) falls back to the CONFIGURED triple when no
  # pointer row resolves, so both sides of the pending predicate become the same
  # expression and no switch can register as pending. An earlier version reported a
  # state of its own here; it warned every pointerless org — nearly all of them
  # healthy, reads and writes on the same space — about a rebuild that was not
  # running. The full reasoning is at the guard in #call.
  describe 'an organisation without a vector-space pointer' do
    it 'stays silent rather than warning about a rebuild it cannot see' do
      record

      result = described_class.call(organisation: organisation)

      expect(organisation.active_embedding_space_id).to be_nil
      expect(result.state).to eq(:none)
      expect(result).not_to be_in_progress
      # Nothing was measured, and nil is how that differs from "measured zero" —
      # a 0-of-0 bar would read as a finished rebuild.
      expect(result.remaining).to be_nil
      expect(result.total).to be_nil
    end

    # The pair that keeps the silence above from being vacuous: the SAME org with the
    # SAME corpus reports a running build the moment it has a pointer. Without this,
    # an implementation that answered :none for everything would pass the example
    # above just as happily.
    it 'reports a running build once the same organisation has one' do
      record
      point_at

      expect(described_class.call(organisation: organisation).state).to eq(:building)
    end
  end

  describe 'a running rebuild' do
    before { point_at }

    it 'counts what is left against the whole corpus' do
      done = record
      record
      record
      embed_into_target(done)

      result = described_class.call(organisation: organisation)

      expect(result.state).to eq(:building)
      expect(result).to be_in_progress
      expect(result.total).to eq(3)
      expect(result.remaining).to eq(2)
      expect(result.completed).to eq(1)
      expect(result.percent).to eq(33)
    end

    # `remaining` must come from the SAME anti-join Actors::FlipEmbeddingModel
    # validates on, or the page can show "0 verbleibend" for a switch the actor then
    # refuses as :incomplete_target. A row that EXISTS but is not indexed is exactly
    # where a laxer count would disagree: retirement clears that flag, and the read
    # seam cannot see an unindexed row.
    #
    # A corpus where SOME records are unindexed and others have no row at all is a
    # half-built target, not a retired one — and it is the case that keeps the
    # :retired_target check below from swallowing every build.
    it 'counts an unindexed row as still missing while other records have no row' do
      symbol = record
      record
      ActsAsTenant.with_tenant(organisation) do
        create(:content_embedding, embeddable: symbol, organisation: organisation, indexed: false)
      end

      result = described_class.call(organisation: organisation)

      expect(result.state).to eq(:building)
      expect(result.remaining).to eq(2)
    end
  end

  # A target that holds a row for EVERY record and is only missing `indexed`: the
  # space was RETIRED, not left half built. Nothing is running — the actor refuses
  # with :retired_target and SwitchWatcherJob deliberately does NOT re-drive a build,
  # because a build repairs the wrong thing. Reported as :building, the customer would
  # watch a number that can never move again (P4c review, M1).
  describe 'a target space that was retired rather than half built' do
    before { point_at }

    it 'reports :retired_target instead of a build that will never progress' do
      symbol = record
      ActsAsTenant.with_tenant(organisation) do
        create(:content_embedding, embeddable: symbol, organisation: organisation, indexed: false)
      end

      result = described_class.call(organisation: organisation)

      expect(result.state).to eq(:retired_target)
      # Still counted as unreachable — `remaining` keeps asking the READABLE question,
      # which is what the flip validates on.
      expect(result.remaining).to eq(1)
      # in_progress?: a switch IS underway, it is simply stuck. Dropping it from that
      # set would hide the state that most needs explaining.
      expect(result).to be_in_progress
    end

    # The same reading the actor makes: retired is decided BEFORE the budget, because
    # no amount of quota moves a space that needs reactivation rather than work.
    it 'prefers :retired_target over :paused' do
      symbol = record
      ActsAsTenant.with_tenant(organisation) do
        create(:content_embedding, embeddable: symbol, organisation: organisation, indexed: false)
      end
      system_credential.update!(included_in_quota: true)
      organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)

      expect(described_class.call(organisation: organisation).state).to eq(:retired_target)
    end
  end

  describe 'a rebuild that has finished' do
    before { point_at }

    it 'reports :awaiting_flip once every record has a readable row in the target' do
      embed_into_target(record)

      result = described_class.call(organisation: organisation)

      expect(result.state).to eq(:awaiting_flip)
      expect(result.remaining).to eq(0)
      expect(result.percent).to eq(100)
    end
  end

  describe 'the quota' do
    # Metered: the credential the RUN bills carries included_in_quota, and the
    # month's hard limit (budget + buffer) is spent.
    def exhaust_quota
      system_credential.update!(included_in_quota: true, embedding_cost_per_1m_cents: 2)
      organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)
    end

    it 'reports :paused when the metered budget is gone' do
      point_at
      record
      exhaust_quota

      result = described_class.call(organisation: organisation)

      expect(result.state).to eq(:paused)
      # Still in_progress: the switch IS underway, it is just not moving. A page
      # that dropped it from that set would stop showing the numbers at exactly the
      # moment the customer needs to know why they stopped changing.
      expect(result).to be_in_progress
      expect(result.remaining).to eq(1)
    end

    # The ORDER, and the one example that fails if the two checks are swapped.
    # Embeddings::SwitchWatcherJob tries the flip FIRST and only reaches its quota
    # check when the actor answers :incomplete_target — so a complete target flips
    # regardless of the budget, and a page reporting "pausiert" here would announce a
    # standstill about an org the watcher flips within the quarter hour.
    it 'prefers :awaiting_flip over :paused when the target is already complete' do
      point_at
      embed_into_target(record)
      exhaust_quota

      expect(described_class.call(organisation: organisation).state).to eq(:awaiting_flip)
    end

    # A lane nobody flagged included_in_quota costs the OPERATOR, not this customer's
    # monthly budget: no gate stops the run, so "pausiert" would announce a standstill
    # that never happens. Same rule the P4b dialog's quota block hangs on
    # (@quota_relevant) — and the pair of examples is what proves the flag is read at
    # all, rather than the budget alone deciding.
    #
    # Set explicitly, not left to a default: the COLUMN defaults to false but the
    # FACTORY sets true (spec/factories/ai_credentials.rb:47), so a reader going by
    # the schema annotation would have this example exactly backwards.
    it 'stays :building for an unmetered lane even with the budget spent' do
      point_at
      record
      system_credential.update!(included_in_quota: false)
      organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)

      expect(organisation.ai_quota_ledger).to be_hard_exhausted
      expect(described_class.call(organisation: organisation).state).to eq(:building)
    end

    # THE example this file was missing, and its absence was invisible: every other
    # quota example ran against a SINGLE openai credential that was both the provider's
    # `active` row and (implicitly) the lane's, so a name-based lookup and an
    # object-based one resolved the same row and no example could tell them apart.
    # Proven, not assumed — reverting #quota_blocked? to the pre-#437 name form
    # (CostCalculator.billing_credential with a provider NAME) left all 20 examples
    # green (P4c review, M2).
    #
    # Two rows on purpose: AiCredential.active_for_provider returns the single
    # `active: true` row per provider name, while a curated package references an
    # ENABLED row instead (Factory#resolve_embedding_credentials:936-937). With two
    # rows of the same provider side by side — the normal case for the EU packages,
    # §4.1 — those are simply different credentials, and the silent direction is the
    # expensive one: the run bills the metered row, the page reports no problem, and
    # the month's budget is gone before anyone looks.
    it 'judges the PACKAGE credential, not the provider default' do
      package = metered_package
      organisation.update_column(:ai_package_id, package.id)
      point_at
      record
      # The provider's ACTIVE row is NOT metered — a name-based lookup lands here and
      # would answer "nothing to pause".
      system_credential.update!(included_in_quota: false)
      organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)

      expect(::AiCredential.active_for_provider('openai')).to eq(system_credential)
      expect(described_class.call(organisation: organisation).state).to eq(:paused)
    end
  end

  # A customer settings page must not 500 over an operator-side configuration fault,
  # and it must not invent a progress statement either. Same posture as the P4b
  # dialog's quota block: say nothing, log for the operator, leave the finding to
  # `embeddings:check_alignment`, which is built to report it.
  describe 'an unresolvable configured lane' do
    it 'reports :none and logs rather than raising' do
      point_at
      system_credential.update!(enabled: false)

      expect(Rails.logger).to receive(:warn).with(/no progress statement/)
      expect(described_class.call(organisation: organisation).state).to eq(:none)
    end
  end

  # The locale file names two keys per state (…packages.progress.<state>_{title,body}).
  # A state added without its texts would render a missing-translation string straight
  # onto a customer page, and only in the state that was just introduced — i.e. the
  # one nobody has seen yet.
  #
  # BOTH keys, not just the title: the first version of this guard checked `_title`
  # alone and would have passed a state with no body at all (P4c review, I3). The
  # matching check that the VIEW can render every state lives in
  # spec/views/organisations/ai_settings/switch_progress_spec.rb — this one owns the
  # texts, that one owns the styling map.
  describe 'STATES' do
    it 'has a title and a body in both locales for every state that renders' do
      (described_class::STATES - [:none]).each do |state|
        %i[title body].each do |part|
          %i[de en].each do |locale|
            # .dig rather than I18n.exists?, which answers true for an en key served by
            # the de fallback and would pass a missing English text.
            expect(
              I18n.backend.translations.dig(
                locale, :views, :organisations, :ai_settings, :packages, :progress,
                :"#{state}_#{part}"
              )
            ).to be_present, "#{locale}: missing progress.#{state}_#{part}"
          end
        end
      end
    end
  end
end

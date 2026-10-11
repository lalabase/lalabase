# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_packages
#
#  id                      :uuid             not null, primary key
#  active                  :boolean          default(FALSE), not null
#  description             :text
#  embedding_dims          :integer
#  embedding_model         :string
#  jurisdiction            :string
#  kind                    :string           default("curated"), not null
#  name                    :string           not null
#  position                :integer          default(0), not null
#  processing_region       :string
#  provider_note           :text
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  embedding_credential_id :uuid
#
# Indexes
#
#  index_ai_packages_on_embedding_credential_id  (embedding_credential_id)
#  index_ai_packages_on_name                     (name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (embedding_credential_id => ai_credentials.id)
#
require 'rails_helper'

# What this file protects (doc/ki_pakete_plan.md §7b.1, E9, §9 Fallen 2/3/6)
# --------------------------------------------------------------------------
# 1. A CURATED package is a promise to the customer — every field the card and
#    the AVV quote must exist. `custom` is the opposite: the placeholder row for
#    "the org's own settings" carries no embedding triple at all, and a blanket
#    presence rule would reject exactly that row.
# 2. Embedding and chat providers stay DECOUPLED (§9 Falle 2). Anthropic cannot
#    embed, so a Claude package NEEDS a foreign embedding credential — the
#    positive test below is the load-bearing one: any coupling logic breaks it.
# 3. `jurisdiction` is a legal claim that ends up in the AVV (§9 Falle 6). The
#    credential facts can contradict it, and then it must not be saveable —
#    while the softer "EU region, foreign provider" case only warns.
# 4. The Vertex probe (E9) may block a save on ONE finding — a clear 404 for
#    model × region — and on nothing else. A Google outage must never stop an
#    operator from maintaining a package.
#
# Validation checks assert errors.details (not message strings) so they are
# locale-independent and pin the error TYPE rather than its wording.
RSpec.describe AiPackage do
  # One probed cell in the shape VertexAvailabilityProbe returns. `available` is
  # derived exactly the way the probe derives it, so a "404 blocks" assertion
  # cannot accidentally pass through the coarser flag.
  def vertex_matrix(region:, model:, status_code:)
    {
      checked_at: Time.current, project_id: 'lala-eu', regions: [region], models: [model],
      results: [{ region: region, model: model, status_code: status_code,
                  available: status_code == 200, info_only: false }]
    }
  end

  def stub_probe(matrix)
    allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(matrix)
  end

  def error_types(record, attribute)
    record.validate
    record.errors.details[attribute].map { |detail| detail[:error] }
  end

  describe 'kind' do
    it 'accepts every declared kind' do
      described_class::KINDS.each do |kind|
        expect(build(:ai_package, kind: kind)).to be_valid, "expected kind #{kind} to be valid"
      end
    end

    it 'rejects a kind outside KINDS' do
      expect(error_types(build(:ai_package, kind: 'premium'), :kind)).to include(:inclusion)
    end
  end

  describe 'name' do
    it 'requires a name — it is the card headline in the catalogue' do
      expect(error_types(build(:ai_package, name: nil), :name)).to include(:blank)
    end

    it 'rejects a duplicate name: two identical cards are indistinguishable' do
      create(:ai_package, name: 'Europäisch')

      expect(error_types(build(:ai_package, name: 'Europäisch'), :name)).to include(:taken)
    end
  end

  describe 'kind-dependent mandatory fields' do
    # Each of these is quoted somewhere a customer or a lawyer reads it: the
    # card (description), the AVV (provider_note, jurisdiction) or the vector
    # space (the embedding triple).
    %i[description provider_note jurisdiction embedding_model embedding_dims embedding_credential].each do |field|
      it "rejects a curated package without #{field}" do
        expect(error_types(build(:ai_package, field => nil), field)).to include(:blank)
      end
    end

    it 'accepts a custom package with none of them — that row has no embedding triple (E1)' do
      package = build(:ai_package, kind: 'custom', description: nil, provider_note: nil,
                                   jurisdiction: nil, embedding_credential: nil,
                                   embedding_model: nil, embedding_dims: nil)

      expect(package).to be_valid
    end
  end

  describe 'embedding_dims' do
    it 'accepts every dimension the app has a storage lane for' do
      Organisation::SUPPORTED_DIMS.each do |dims|
        expect(build(:ai_package, embedding_dims: dims)).to be_valid, "expected #{dims} to be valid"
      end
    end

    it 'rejects a dimension outside SUPPORTED_DIMS — nothing could serve that space' do
      package = build(:ai_package, embedding_dims: 999)

      expect(error_types(package, :embedding_dims)).to include(:inclusion)
      # The inclusion validator keeps its type; the custom key only redirects the
      # wording. Asserting the rendered message pins that redirect AND proves the
      # key is actually present in the locale file.
      expect(package.errors[:embedding_dims]).to eq(
        [I18n.t('activerecord.errors.models.ai_package.attributes.embedding_dims.supported_dimension')]
      )
    end
  end

  describe 'jurisdiction' do
    # Each rung is paired with credential facts that MATCH it. Since E12 the
    # claim is checked against both axes of §3, so "every rung on one arbitrary
    # credential" is no longer a question the model can answer with yes — what
    # this still pins is that all five rungs are accepted values, and it now pins
    # the matrix that maps facts to rungs alongside it.
    it 'accepts every rung of the §3 ladder on credentials that match it' do
      {
        'eu_native' => { company_domicile: 'eu', region: 'eu' },
        'eu_region_foreign_provider' => { company_domicile: 'non_eu', region: 'eu' },
        'eu_provider_foreign_region' => { company_domicile: 'eu', region: 'us' },
        'non_eu' => { company_domicile: 'non_eu', region: 'us' },
        # The third axis (§3.2) makes no claim the matrix could contradict.
        'self_hosted' => { region: 'eu' }
      }.each do |jurisdiction, facts|
        credential = create(:ai_credential, :embedding_only, **facts)
        package = build(:ai_package, jurisdiction: jurisdiction, embedding_credential: credential)

        expect(package).to be_valid, "expected #{jurisdiction} to be valid, got #{package.errors.full_messages}"
      end
    end

    it 'rejects an invented rung — the four are the ones §3 can defend' do
      expect(error_types(build(:ai_package, jurisdiction: 'eu_ish'), :jurisdiction)).to include(:inclusion)
    end
  end

  describe 'embedding credential capability' do
    # The form's select offers only enabled, embedding-purposed, embedding-capable
    # credentials. These validations catch manipulation and the race where a
    # credential is disabled between rendering and submitting the form.
    it 'accepts an enabled credential with an embedding purpose' do
      expect(build(:ai_package, embedding_credential: create(:ai_credential, :embedding_only, region: 'eu'))).to be_valid
    end

    it 'rejects a disabled credential' do
      package = build(:ai_package, embedding_credential: create(:ai_credential, :disabled, region: 'eu'))

      expect(error_types(package, :embedding_credential)).to include(:disabled)
    end

    it 'rejects a chat-only credential — its purpose excludes embeddings' do
      package = build(:ai_package, embedding_credential: create(:ai_credential, :chat_only, region: 'eu'))

      expect(error_types(package, :embedding_credential)).to include(:wrong_purpose)
    end

    it 'rejects a provider that cannot embed at all' do
      # An anthropic row with an embedding purpose cannot be created through the
      # credential's own capability rule — so the honest reproduction writes the
      # provider past it, which is what a manipulated form field achieves.
      credential = create(:ai_credential, :embedding_only, region: 'eu')
      credential.update_column(:provider, 'anthropic')

      package = build(:ai_package, embedding_credential: credential.reload)

      expect(error_types(package, :embedding_credential)).to include(:not_embedding_capable)
    end
  end

  # THE test of §9 Falle 2. Anthropic has no embedding model, so every Claude
  # package must borrow one — if this goes red, someone coupled the two
  # credential slots and made the flagship package unbuildable.
  describe 'decoupled embedding and chat providers (§9 Falle 2)' do
    it 'accepts anthropic chat tiers next to an openai embedding credential' do
      package = build(:ai_package, embedding_credential: create(:ai_credential, :embedding_only, region: 'eu'))
      AiPackageTier::KEYS.each_with_index do |key, index|
        package.tiers << build(:ai_package_tier, ai_package: package, key: key, position: index,
                                                 label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                                 chat_credential: create(:ai_credential, :anthropic, region: 'eu'))
      end

      expect(package).to be_valid
      expect { package.save! }.to change(described_class, :count).by(1)
    end
  end

  describe 'jurisdiction consistency (§9 Falle 6)' do
    let(:us_credential) { create(:ai_credential, :embedding_only, region: 'us') }

    it 'rejects an eu_native claim over a US-hosted embedding credential' do
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: us_credential)

      expect(error_types(package, :jurisdiction)).to include(:us_credential_conflict)
    end

    it 'also sees a US credential that only a tier references' do
      package = build(:ai_package, jurisdiction: 'eu_native')
      package.tiers << build(:ai_package_tier, ai_package: package,
                                               chat_credential: create(:ai_credential, :chat_only, region: 'us'))

      expect(error_types(package, :jurisdiction)).to include(:us_credential_conflict)
    end

    it 'names the offending credential so the operator can act on it' do
      credential = create(:ai_credential, :embedding_only, region: 'us', display_name: 'OpenAI (US)')
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)
      package.validate

      expect(package.errors[:jurisdiction].join).to include('OpenAI (US)')
    end

    it 'accepts the same US credential under a non_eu claim — that claim is honest' do
      expect(build(:ai_package, jurisdiction: 'non_eu', embedding_credential: us_credential)).to be_valid
    end

    # Review finding. `region` is nullable and its select carries a blank option,
    # so "not stated" is the DEFAULT state of any credential nobody classified —
    # and an unrecorded region cannot prove an UNDERSTATEMENT. Blocking there
    # accused the operator of the exact opposite of the facts ("all credentials
    # process inside the EU" about credentials that say nothing at all), and
    # since ① was already refused by :unknown_region_conflict, no matrix rung was
    # saveable at all. Fail-closed belongs to the strict claim, not the
    # conservative one — which is why the company axis has always had this guard.
    context 'with a credential whose region nobody recorded' do
      let(:unclassified) { create(:ai_credential, :embedding_only) }

      it 'accepts the conservative non_eu claim' do
        expect(unclassified.region).to be_blank
        expect(build(:ai_package, jurisdiction: 'non_eu', embedding_credential: unclassified)).to be_valid
      end

      it 'accepts an eu_provider_foreign_region claim on an EU company' do
        unclassified.update!(company_domicile: 'eu')

        expect(build(:ai_package, jurisdiction: 'eu_provider_foreign_region',
                                  embedding_credential: unclassified)).to be_valid
      end

      it 'still refuses the strict eu_native claim — unknown stays with the violating case' do
        package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: unclassified)

        expect(error_types(package, :jurisdiction)).to include(:unknown_region_conflict)
      end

      # The understatement refusal itself must survive: it only ever applied to a
      # RECORDED region, and that half is what the guard must not soften.
      it 'still refuses a non_eu claim when every region IS recorded as EU' do
        eu_recorded = create(:ai_credential, :embedding_only, region: 'eu')
        package = build(:ai_package, jurisdiction: 'non_eu', embedding_credential: eu_recorded)

        expect(error_types(package, :jurisdiction)).to include(:eu_region_understated)
      end
    end
  end

  describe '#jurisdiction_warnings' do
    let(:google_credential) { create(:ai_credential, :google) }

    # Vertex in europe-west3 is §3's "EU region, foreign provider" rung. Calling
    # it eu_native mislabels the rung, it does not misstate where the data sits —
    # so this informs the operator instead of blocking the save.
    it 'reports a Vertex credential under an eu_native claim WITHOUT blocking' do
      stub_probe(nil)
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: google_credential,
                                   embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      expect(package).to be_valid
      expect(package.jurisdiction_warnings).to eq([google_credential])
    end

    it 'also reports a Vertex credential referenced only by a tier' do
      stub_probe(nil)
      package = build(:ai_package, jurisdiction: 'eu_native')
      package.tiers << build(:ai_package_tier, ai_package: package, chat_credential: google_credential)

      expect(package.jurisdiction_warnings).to eq([google_credential])
    end

    it 'stays silent when the package does not claim eu_native' do
      stub_probe(nil)
      package = build(:ai_package, jurisdiction: 'eu_region_foreign_provider',
                                   embedding_credential: google_credential,
                                   embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      expect(package.jurisdiction_warnings).to eq([])
    end

    it 'stays silent for an eu_native package without a foreign-provider credential' do
      expect(build(:ai_package, jurisdiction: 'eu_native').jurisdiction_warnings).to eq([])
    end
  end

  describe 'Vertex model availability (E9, §9 Falle 3)' do
    let(:google_credential) { create(:ai_credential, :google) }
    # additional_config['location'] of the :google trait — the region every probe
    # result has to be read against.
    let(:region) { 'europe-west3' }

    def google_package(model: 'gemini-embedding-001')
      build(:ai_package, embedding_credential: google_credential, embedding_model: model,
                         embedding_dims: 3072)
    end

    it 'blocks the save on a clear 404 — the one finding that predicts silent breakage' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-embedding-001', status_code: 404))
      package = google_package

      expect(error_types(package, :embedding_model)).to include(:vertex_model_unavailable)
      expect(package.errors[:embedding_model].join).to include('gemini-embedding-001').and include(region)
    end

    it 'saves through a transport failure (no status code) — an outage must not block maintenance' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-embedding-001', status_code: nil))

      expect(google_package).to be_valid
    end

    it 'saves through an auth/quota answer — only 404 is a verdict' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-embedding-001', status_code: 403))

      expect(google_package).to be_valid
    end

    it 'saves when the probe itself raises' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached)
        .and_raise(Lalabase::Llm::VertexAvailabilityProbe::ProbeError, 'no service account')

      expect(google_package).to be_valid
    end

    it 'saves when the matrix does not cover the configured model at all' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-2.5-pro', status_code: 404))

      expect(google_package).to be_valid
    end

    it 'reads the 404 against the credential region, not against any red cell' do
      stub_probe(vertex_matrix(region: 'europe-west9', model: 'gemini-embedding-001', status_code: 404))

      expect(google_package).to be_valid
    end

    it 'never probes for a non-google credential' do
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:cached)

      build(:ai_package).validate
    end

    # Probing on every #valid? would hide network I/O behind an innocent-looking
    # call: the save path may probe (§7b.1), an unrelated edit may not.
    it 'does not probe again when neither credential nor model changed' do
      stub_probe(nil)
      package = google_package
      package.save!

      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:cached)
      package.update!(name: 'Umbenannt')
    end

    it 'probes again when the model changes' do
      stub_probe(nil)
      package = google_package
      package.save!

      stub_probe(vertex_matrix(region: region, model: 'gemini-2.0-flash', status_code: 404))
      package.embedding_model = 'gemini-2.0-flash'

      expect(error_types(package, :embedding_model)).to include(:vertex_model_unavailable)
    end
  end

  describe 'associations' do
    it 'takes its tiers with it when it is deleted' do
      package = create(:ai_package, :with_tiers)

      expect { package.destroy }.to change(AiPackageTier, :count).by(-2)
    end
  end

  # The project rule is DE *and* EN for every user-facing string; a half-translated
  # validation only shows up when someone switches locale, which nobody does while
  # testing an admin form.
  describe 'error messages' do
    it 'ships every custom message in both locales' do
      keys = %w[
        embedding_credential.disabled
        embedding_credential.wrong_purpose
        embedding_credential.not_embedding_capable
        embedding_dims.supported_dimension
        embedding_model.vertex_model_unavailable
        jurisdiction.us_credential_conflict
      ].map { |key| "activerecord.errors.models.ai_package.attributes.#{key}" }

      %i[de en].each do |locale|
        keys.each do |key|
          expect(I18n.exists?(key, locale)).to be(true), "missing translation #{key} (#{locale})"
        end
      end
    end
  end

  # The reverse-lookup feeding the admin credential pages (§7b.2 "Pakete"
  # column) and the destroy guard. The consumers pin the rendered OUTPUT; this
  # pins the SHAPE they rely on — role/label semantics and the absent-key
  # contract for unreferenced credentials.
  describe '.references_by_credential' do
    it 'groups embedding and tier references per credential id, skipping unreferenced ids' do
      package = create(:ai_package, :with_tiers)
      embedding_id = package.embedding_credential_id
      fast_tier = package.tiers.find_by(key: 'fast')
      unreferenced = create(:ai_credential)

      result = AiPackage.references_by_credential([embedding_id, fast_tier.chat_credential_id, unreferenced.id])

      expect(result.fetch(embedding_id))
        .to include(package: package, role: :embedding, label: nil)
      expect(result.fetch(fast_tier.chat_credential_id))
        .to include(package: package, role: :tier, label: fast_tier.label)
      # No key at all — the empty list is the caller's .fetch(id, []) default,
      # so an unreferenced credential costs neither a row nor a lookup.
      expect(result).not_to have_key(unreferenced.id)
    end
  end
end

# ---------------------------------------------------------------------------
# Regressions from the pre-landing review of PR #399. Each block below pins a
# defect that was REPRODUCED on this branch before the fix — the comment says
# what went wrong, so a later refactor cannot quietly restore it.
# ---------------------------------------------------------------------------
RSpec.describe AiPackage, 'review regressions' do
  def stub_probe(matrix = nil)
    allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(matrix)
  end

  # Error TYPES, not message strings: locale-independent, and it pins the reason
  # rather than its wording (same rule as the first half of this file).
  def error_types(record, attribute)
    record.validate
    record.errors.details[attribute].map { |detail| detail[:error] }
  end

  describe 'jurisdiction fails CLOSED on an unstated residency (§9 Falle 6)' do
    # The original rule only rejected region == 'us'. `region` is nullable and
    # its select carries a blank option, so "nobody said" — the DEFAULT state of
    # every credential no one classified — read as compliant, and an eu_native
    # package on a plain OpenAI credential validated clean. That is precisely
    # the false AVV assurance the validation exists to prevent.
    it 'refuses eu_native when a referenced credential has no stated region' do
      credential = create(:ai_credential, provider: 'openai', purpose: 'both', region: nil)
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)

      package.validate

      expect(package.errors.details[:jurisdiction].map { |d| d[:error] })
        .to include(:unknown_region_conflict)
    end

    it 'names the offending credential so the operator knows where to look' do
      credential = create(:ai_credential, provider: 'openai', purpose: 'both',
                                          region: nil, display_name: 'Mistral EU')
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)

      package.validate

      expect(package.errors.full_messages.join).to include('Mistral EU')
    end

    # A Vertex credential states its residency as additional_config['location'],
    # NOT in `region`. Asking `region` alone would flag every google package —
    # and collide with #jurisdiction_warnings, which deliberately only WARNS.
    it 'accepts a google credential that states its location, warning instead of blocking' do
      stub_probe
      google = create(:ai_credential, :google, region: nil)
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: google,
                                   embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      package.validate

      expect(package.errors.details[:jurisdiction].map { |d| d[:error] })
        .not_to include(:unknown_region_conflict)
      # The softer §3 reading still applies — warned, not blocked.
      expect(package.jurisdiction_warnings).to contain_exactly(google)
    end

    it 'still rejects an outright US credential' do
      credential = create(:ai_credential, provider: 'openai', purpose: 'both', region: 'us')
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)

      package.validate

      expect(package.errors.details[:jurisdiction].map { |d| d[:error] })
        .to include(:us_credential_conflict)
    end
  end

  describe 'duplicate tier keys report instead of raising' do
    # AiPackageTier's own uniqueness validation queries the DB, so two UNSAVED
    # siblings of one package never see each other. `key` used to be a permitted
    # hidden field, so a tampered form reached the unique index and 500'd with
    # ActiveRecord::RecordNotUnique. Only the parent holds both rungs, so only
    # the parent can report it.
    it 'adds a readable error rather than letting the DB index raise' do
      credential = create(:ai_credential, region: 'eu')
      package = build(:ai_package)
      %w[fast fast].each_with_index do |key, index|
        package.tiers << build(:ai_package_tier, ai_package: package, key: key, position: index,
                                                 label: AiPackageTier::DEFAULT_LABELS.fetch('fast'),
                                                 chat_credential: credential)
      end

      expect(package).not_to be_valid
      expect(package.errors.details[:tiers].map { |d| d[:error] }).to include(:duplicate_key)
      expect { package.save }.not_to raise_error
    end

    it 'accepts the two distinct rungs of the real ladder' do
      expect(build(:ai_package, :with_tiers)).to be_valid
    end
  end

  describe 'a PUBLISHED curated package must carry the whole ladder' do
    # Found by the Codex cross-model pass. Nothing enforced the ladder: a curated
    # package with ZERO tiers — or only 'fast' — validated, saved and published,
    # and the customer would have picked a card with no chat model behind it.
    # The admin form always posts both slots, so this only bites the paths that
    # bypass it: seeds, console, a POST omitting tiers_attributes entirely.
    it 'refuses to publish a package with no tiers at all' do
      package = build(:ai_package, active: true)

      expect(package).not_to be_valid
      expect(package.errors.details[:tiers].map { |d| d[:error] }).to include(:incomplete_ladder)
    end

    it 'refuses to publish a package carrying only the fast rung' do
      package = build(:ai_package, active: true)
      package.tiers << build(:ai_package_tier, ai_package: package, key: 'fast', position: 0,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch('fast'))

      expect(package).not_to be_valid
      expect(package.errors.details[:tiers].map { |d| d[:error] }).to include(:incomplete_ladder)
    end

    it 'names the missing rung so the operator knows what to fill in' do
      package = build(:ai_package, active: true)
      package.tiers << build(:ai_package_tier, ai_package: package, key: 'fast', position: 0,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch('fast'))

      package.validate

      expect(package.errors.full_messages.join).to include('thorough')
    end

    it 'publishes happily once both rungs are there' do
      expect(build(:ai_package, :with_tiers, active: true)).to be_valid
    end

    # The DRAFT state is explicitly the place to finish a package in peace
    # ("Unveröffentlichte Pakete lassen sich in Ruhe fertig pflegen"), and a
    # legacy one-rung row has to stay editable long enough to complete it.
    it 'leaves an UNPUBLISHED package free to be incomplete' do
      expect(build(:ai_package, active: false)).to be_valid
    end

    # `custom` is the P2 placeholder row for "the org's own settings" — it
    # carries no ladder by design.
    it 'does not impose the ladder on a custom package' do
      package = build(:ai_package, kind: 'custom', active: true, description: nil,
                                   provider_note: nil, jurisdiction: nil,
                                   embedding_credential: nil, embedding_model: nil,
                                   embedding_dims: nil)

      expect(package).to be_valid
    end
  end

  describe 'blank position does not reach the NOT NULL constraint' do
    # position is NOT NULL with a DB default, but a cleared number_field submits
    # "" — cast to nil and written EXPLICITLY, so the default never applies and
    # the INSERT died with ActiveRecord::NotNullViolation (an unhandled 500 that
    # also ate the operator's form input).
    it 'normalises a blank package position to 0' do
      package = build(:ai_package, position: '')

      expect { package.save! }.not_to raise_error
      expect(package.reload.position).to eq(0)
    end

    it 'normalises a blank tier position to 0' do
      package = create(:ai_package)
      tier = build(:ai_package_tier, ai_package: package, position: '')

      expect { tier.save! }.not_to raise_error
      expect(tier.reload.position).to eq(0)
    end
  end

  describe 'tier credentials are batched on the UPDATE path too' do
    # #preload_tier_credentials filtered on association.loaded?. After the
    # controller's eager load, a nested-attributes write to chat_credential_id
    # leaves the association loaded but STALE, so `pending` came out empty and
    # Rails re-fetched one credential per rung — the N+1 the method exists to
    # prevent. Prosopite (raise = true in test) fails this example if it returns.
    it 'issues no per-rung credential lookup when both rungs change at once' do
      package = create(:ai_package, :with_tiers)
      replacements = Array.new(2) { create(:ai_credential, purpose: 'chat', region: 'eu') }
      reloaded = AiPackage.includes(:embedding_credential, tiers: :chat_credential).find(package.id)
      tiers = reloaded.tiers.to_a

      expect do
        reloaded.update!(tiers_attributes: [
                           { id: tiers[0].id, chat_credential_id: replacements[0].id },
                           { id: tiers[1].id, chat_credential_id: replacements[1].id }
                         ])
      end.not_to raise_error

      expect(reloaded.tiers.map(&:chat_credential_id)).to match_array(replacements.map(&:id))
    end
  end

  describe 'the Vertex check never performs network I/O from a validation' do
    # Validations run INSIDE the save transaction, and a cold-cache .call fans
    # out 5 regions x up to 6 models at concurrency 8 (~40 s) while holding a PG
    # connection — on a production Puma with two request slots in total.
    it 'reads the probe CACHE and never triggers a fresh probe' do
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:call)
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(nil)

      google = create(:ai_credential, :google)
      package = build(:ai_package, embedding_credential: google, jurisdiction: 'eu_region_foreign_provider',
                                   embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      expect(package).to be_valid
    end

    # Publishing is the save that puts the package in front of customers, and
    # Google retires models between one save and the next — so `active` counts
    # as a change worth re-judging. Cheap, now that the lookup is cache-only.
    it 're-judges the model when the package is published' do
      stub_probe
      google = create(:ai_credential, :google)
      package = create(:ai_package, embedding_credential: google, jurisdiction: 'eu_region_foreign_provider',
                                    embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      package.active = true

      expect(package.send(:embedding_vertex_check_due?)).to be(true)
    end
  end

  describe 'badge styles cover every declared rung' do
    # The colour map used to be four string literals inside the view, so a fifth
    # rung would have fallen through to a silent grey badge with nothing red.
    it 'has exactly one style per JURISDICTIONS entry' do
      expect(described_class::JURISDICTION_BADGE_STYLES.keys).to match_array(described_class::JURISDICTIONS)
    end
  end

  # E12 (§3.3/§3.4): the rung is DERIVED from two independent credential facts —
  # company seat × processing location — instead of being believed from the form.
  # Before this, `eu_native` was only checked against region == 'us' and warned
  # only for the provider name 'google', so a non-EU company with an EU endpoint
  # under any other provider name was waved through as ① without a word — and
  # after P0 the three EU presets all run under one such name.
  describe '#derived_jurisdiction (the §3 matrix, read off the credentials)' do
    def package_with(credential)
      build(:ai_package, embedding_credential: credential, jurisdiction: nil)
    end

    # ① EU company, EU processing.
    it 'derives eu_native from an EU company processing in the EU' do
      credential = create(:ai_credential, :eu_company, region: 'eu')

      expect(package_with(credential).derived_jurisdiction).to eq('eu_native')
    end

    # ② the juristically HARD field (§3.1) — an EU server does not undo a
    # third-country parent company.
    it 'derives eu_region_foreign_provider from a non-EU company on an EU region' do
      credential = create(:ai_credential, :non_eu_company, region: 'eu')

      expect(package_with(credential).derived_jurisdiction).to eq('eu_region_foreign_provider')
    end

    # ③ the field that had no value at all until E12 and was forced into a
    # firm-seat-erasing non_eu.
    it 'derives eu_provider_foreign_region from an EU company on a US region' do
      credential = create(:ai_credential, :eu_company, region: 'us')

      expect(package_with(credential).derived_jurisdiction).to eq('eu_provider_foreign_region')
    end

    it 'derives non_eu when neither axis is inside' do
      credential = create(:ai_credential, :non_eu_company, region: 'us')

      expect(package_with(credential).derived_jurisdiction).to eq('non_eu')
    end

    it 'reads a Vertex location out of additional_config, not out of region' do
      eu_vertex = create(:ai_credential, :google, :non_eu_company, region: nil)
      global_vertex = create(:ai_credential, :google, :non_eu_company,
                             region: nil, name: 'Vertex global',
                             additional_config: { 'project_id' => 'lala', 'location' => 'global' })

      expect(package_with(eu_vertex).derived_jurisdiction).to eq('eu_region_foreign_provider')
      expect(package_with(global_vertex).derived_jurisdiction).to eq('non_eu')
    end

    it 'is not derivable while an axis is unrecorded' do
      no_seat = create(:ai_credential, region: 'eu')
      no_region = create(:ai_credential, :eu_company, region: nil)

      expect(package_with(no_seat).derived_jurisdiction).to be_nil
      expect(package_with(no_region).derived_jurisdiction).to be_nil
    end

    # The §3 rule "the worse classification wins", aggregated per AXIS. ② and ③
    # are not ordered against each other (§7.1) — but a package holding both has
    # a non-EU company AND non-EU processing in it, which is ④.
    it 'combines a ② and a ③ credential into ④' do
      package = build(:ai_package, jurisdiction: nil,
                                   embedding_credential: create(:ai_credential, :non_eu_company, region: 'eu'))
      package.tiers << build(:ai_package_tier, ai_package: package,
                                               chat_credential: create(:ai_credential, :eu_company, region: 'us'))

      expect(package.derived_jurisdiction).to eq('non_eu')
    end

    # False beats nil: one credential known to sit outside settles the axis no
    # matter what the others left blank. This is what keeps the US-region refusal
    # alive on rows that have no company seat recorded.
    it 'stays derivable when the unknown axis cannot change the answer' do
      package = build(:ai_package, jurisdiction: nil,
                                   embedding_credential: create(:ai_credential, :non_eu_company, region: 'us'))
      package.tiers << build(:ai_package_tier, ai_package: package,
                                               chat_credential: create(:ai_credential, :non_eu_company, region: nil))

      expect(package.derived_jurisdiction).to eq('non_eu')
    end

    it 'is not derivable for a package that references no credential at all' do
      expect(described_class.new(kind: 'custom', name: 'Ohne Zugänge').derived_jurisdiction).to be_nil
    end

    # `self_hosted` is the THIRD axis (§3.2) and the matrix cannot express it, so
    # the derivation answers the MATRIX question about a self-hosted package's
    # credentials and says nothing about who operates them. That is right here —
    # #derived_jurisdiction is defined as "the rung read off the credentials".
    # Reconciling the two readings is #effective_jurisdiction's job (next block).
    it 'answers the matrix question even for a package claiming self_hosted' do
      credential = create(:ai_credential, :eu_company, region: 'eu')
      package = build(:ai_package, jurisdiction: 'self_hosted', embedding_credential: credential)

      expect(package.derived_jurisdiction).to eq('eu_native')
    end

    # The reason the derivation exists next to the stored claim at all: the claim
    # is validated ONCE, at save time, while the facts it rests on live on rows
    # somebody else maintains. A seat corrected later must move the rung without
    # anyone re-saving the package.
    it 'follows a credential fact that changed after the package was saved' do
      credential = create(:ai_credential, :eu_company, region: 'eu')
      package = create(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)
      credential.update_columns(company_domicile: AiCredential::COMPANY_DOMICILE_NON_EU)

      expect(package.reload.derived_jurisdiction).to eq('eu_region_foreign_provider')
      expect(package.jurisdiction).to eq('eu_native')
    end
  end

  # The ONE rung a customer-facing surface may state (P5) — shared by the
  # catalogue card and the chat's Art. 13 notice, so the same claim reads the
  # same everywhere. Each example is a mutation probe against one branch of the
  # method: dropping the self_hosted guard, the derived-first preference or the
  # stored fallback breaks exactly one of them.
  describe '#effective_jurisdiction (what a customer surface may state)' do
    it 'prefers the derived rung over a stale stored claim (mutation M4)' do
      package = build(:ai_package, jurisdiction: 'eu_native',
                                   embedding_credential: create(:ai_credential, :non_eu_company, region: 'eu'))

      expect(package.effective_jurisdiction).to eq('eu_region_foreign_provider')
    end

    it 'falls back to the stored claim while nothing is classified' do
      package = build(:ai_package, jurisdiction: 'eu_native',
                                   embedding_credential: create(:ai_credential, region: nil))

      expect(package.effective_jurisdiction).to eq('eu_native')
    end

    # The P2-B3 finding, now settled in the model: a self-hosted claim names WHO
    # processes (§3.2), which no matrix derivation over the credentials can
    # answer — deriving here would relabel the package as ① and erase the
    # "operator is the processor" claim together with its note.
    it 'keeps a self_hosted claim even when the credentials derive a matrix rung' do
      package = build(:ai_package, jurisdiction: 'self_hosted',
                                   embedding_credential: create(:ai_credential, :eu_company, region: 'eu'))

      expect(package.effective_jurisdiction).to eq('self_hosted')
    end

    it 'is blank when nothing is classified and nothing is claimed' do
      expect(described_class.new(kind: 'custom', name: 'Ohne Angabe').effective_jurisdiction).to be_blank
    end
  end

  # The two customer filters of §7.1 are these two axes and nothing else — a
  # filter can only filter on a value that exists.
  describe 'the two filter axes' do
    it 'answers both axes for an EU-native package' do
      package = build(:ai_package, embedding_credential: create(:ai_credential, :eu_company, region: 'eu'))

      expect(package.eu_company?).to be(true)
      expect(package.eu_processing_only?).to be(true)
    end

    it 'separates the axes — a ② package passes one and fails the other' do
      package = build(:ai_package, jurisdiction: 'eu_region_foreign_provider',
                                   embedding_credential: create(:ai_credential, :non_eu_company, region: 'eu'))

      expect(package.eu_company?).to be(false)
      expect(package.eu_processing_only?).to be(true)
    end

    # FAIL CLOSED: the strictest filter combination is the default (§7.1), so an
    # unclassified package must be hidden rather than shown.
    it 'answers false, never nil, for an unrecorded axis' do
      package = build(:ai_package, embedding_credential: create(:ai_credential, region: 'eu'))

      expect(package.eu_company?).to be(false)
    end

    # BUG (adversarial review 2026-08-02): #axis_of folds an EMPTY credential list
    # to `true` — no answer is `false`, no answer is `nil`, so the "everything is
    # inside" branch wins by vacuous truth. A package that references nothing has
    # nobody vouching for it and is exactly what the fail-closed rule one example
    # up describes, yet it passes BOTH strict filters and lands in the default
    # catalogue view.
    #
    # Unreachable for `curated` (embedding_credential is presence-validated) and
    # reachable for `custom` — the row §7b.1 foresees seeding. It travels with the
    # nil-credential crash in factory_spec: same row, two symptoms.
    it 'hides a package that vouches for nothing' do
      package = described_class.new(kind: 'custom', name: 'Ohne Zugänge')

      expect(package.eu_company?).to be(false)
      expect(package.eu_processing_only?).to be(false)
    end
  end

  describe 'the jurisdiction claim is checked against BOTH axes (E12)' do
    it 'refuses eu_native for a credential of a non-EU company' do
      credential = create(:ai_credential, :non_eu_company, region: 'eu')
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)

      expect(error_types(package, :jurisdiction)).to include(:foreign_company_conflict)
    end

    # The E12 headline case: an openai_compatible credential says nothing about
    # its company through its provider name, so before the field this saved clean.
    it 'names the offending credential rather than the provider' do
      credential = create(:ai_credential, :openai_compatible, :non_eu_company,
                          display_name: 'US-Endpunkt (EU-Region)')
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)
      package.validate

      expect(package.errors.full_messages.join).to include('US-Endpunkt (EU-Region)')
    end

    it 'refuses a claim that understates the facts in either direction' do
      eu_only = build(:ai_package, jurisdiction: 'non_eu',
                                   embedding_credential: create(:ai_credential, :eu_company, region: 'eu'))

      expect(error_types(eu_only, :jurisdiction))
        .to include(:eu_company_understated, :eu_region_understated)
    end

    it 'accepts a claim that matches the derived rung' do
      credential = create(:ai_credential, :non_eu_company, region: 'eu')
      package = build(:ai_package, jurisdiction: 'eu_region_foreign_provider', embedding_credential: credential)

      expect(error_types(package, :jurisdiction)).to be_empty
    end

    # self_hosted is the THIRD axis (§3.2) — it answers "who is the processor",
    # not "where", so the matrix has nothing to contradict.
    it 'exempts self_hosted from the matrix' do
      credential = create(:ai_credential, :non_eu_company, region: 'us')
      package = build(:ai_package, jurisdiction: 'self_hosted', embedding_credential: credential)

      expect(error_types(package, :jurisdiction)).to be_empty
    end

    # The asymmetry between the two axes is deliberate: company_domicile is NULL
    # on every row written before E12, so an unrecorded seat may not invalidate a
    # stored package — an unrecorded REGION always could, and still does.
    it 'lets an unrecorded company seat pass while an unrecorded region still blocks' do
      no_seat = build(:ai_package, jurisdiction: 'eu_native',
                                   embedding_credential: create(:ai_credential, region: 'eu'))
      no_region = build(:ai_package, jurisdiction: 'eu_native',
                                     embedding_credential: create(:ai_credential, :eu_company, region: nil))

      expect(error_types(no_seat, :jurisdiction)).to be_empty
      expect(error_types(no_region, :jurisdiction)).to include(:unknown_region_conflict)
    end

    # The pre-E12 heuristic survives exactly where the field is silent — as a
    # WARNING, because a wrong error would make a legitimate package unsaveable.
    it 'still only warns about a google credential with no recorded seat' do
      stub_probe
      google = create(:ai_credential, :google, region: nil)
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: google,
                                   embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      expect(error_types(package, :jurisdiction)).to be_empty
      expect(package.jurisdiction_warnings).to contain_exactly(google)
    end

    it 'warns off the FIELD once it is recorded, without needing a known name' do
      credential = create(:ai_credential, :openai_compatible, :non_eu_company)
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)

      expect(package.jurisdiction_warnings).to contain_exactly(credential)
    end

    # The field beats the name in BOTH directions, which is the whole of E12: the
    # provider-name heuristic is the DEGRADED reading and may only speak where
    # nobody recorded a seat. Without this the pre-E12 rule would keep flagging a
    # Google row whose seat an operator has since classified — a warning that
    # cannot be silenced teaches people to ignore warnings.
    it 'stops warning about a google credential once its seat is recorded as EU' do
      stub_probe
      google = create(:ai_credential, :google, :eu_company, region: nil)
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: google,
                                   embedding_model: 'gemini-embedding-001', embedding_dims: 3072)

      expect(package.jurisdiction_warnings).to be_empty
    end

    # The one axis that has ALWAYS blocked, kept alive next to the new one: a
    # recorded EU seat must not buy a pass for a US region. Stated as its own
    # example because the two axes are checked by two methods, and a refactor that
    # collapsed them into "derived == claimed" would go silent the moment the
    # company axis is unknown — which is the majority of stored rows.
    it 'refuses eu_native on a US region even when the seat is recorded as EU' do
      credential = create(:ai_credential, :eu_company, region: 'us')
      package = build(:ai_package, jurisdiction: 'eu_native', embedding_credential: credential)

      expect(error_types(package, :jurisdiction)).to include(:us_credential_conflict)
    end
  end

  # P2's switch guard (§8): the customer catalogue asks this BEFORE offering a
  # card, and Actors::SelectAiPackage asks it again before writing — so the two
  # cannot disagree about what is on offer.
  describe '#embedding_switch_for?' do
    let(:organisation) { create(:organisation) }

    before do
      ActsAsTenant.current_tenant = organisation
      create(:ai_credential, :active, provider: 'openai', region: 'eu')
    end

    after { ActsAsTenant.current_tenant = nil }

    it 'is false for a package that leaves the triple untouched' do
      embedding = create(:ai_credential, :embedding_only, provider: 'openai', region: 'eu')
      package = build(:ai_package, embedding_credential: embedding,
                                   embedding_model: 'text-embedding-3-small', embedding_dims: 1536)

      expect(package.embedding_switch_for?(organisation)).to be(false)
    end

    it 'is true for a package on another vector space' do
      embedding = create(:ai_credential, :openai_compatible, :embedding_only, :eu_company)
      package = build(:ai_package, embedding_credential: embedding,
                                   embedding_model: 'mistral-embed', embedding_dims: 1024)

      expect(package.embedding_switch_for?(organisation)).to be(true)
    end

    it 'is nil-safe and fails closed when nothing resolves' do
      package = build(:ai_package)
      AiCredential.update_all(enabled: false)
      Rails.cache.clear

      expect(package.embedding_switch_for?(nil)).to be(false)
      expect(package.embedding_switch_for?(organisation)).to be(true)
    end
  end

  describe '.references_by_credential edge cases' do
    it 'returns an empty hash for empty, nil and nil-only id lists' do
      expect(described_class.references_by_credential([])).to eq({})
      expect(described_class.references_by_credential(nil)).to eq({})
      expect(described_class.references_by_credential([nil])).to eq({})
    end
  end
  # KI-Pakete P3 (§2.1): the rung helper paths run on. ONE method, because two
  # places need the identical answer — the routing (Factory#curated_tier) and the
  # customer-facing hint that NAMES the rung in the tier switcher. A second
  # derivation in the view is how a screen ends up promising a rung the request
  # does not use.
  describe '#utility_tier' do
    let(:credential) { create(:ai_credential, region: 'eu', company_domicile: 'eu') }

    def package_with(*keys)
      package = create(:ai_package, embedding_credential: credential,
                                    embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
      keys.each_with_index do |key, index|
        package.tiers.create!(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                              position: index, chat_credential: credential)
      end
      package
    end

    it 'is the fast rung on a full ladder' do
      expect(package_with('fast', 'thorough').utility_tier.key).to eq('fast')
    end

    # Not position 0 by luck: asked on a package where the fast rung is stored
    # LAST, so "the cheapest one" cannot be read as "the first one".
    it 'is the fast rung even when it sits last' do
      package = create(:ai_package, embedding_credential: credential,
                                    embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
      package.tiers.create!(key: 'thorough', label: 'Gründlich', position: 0, chat_credential: credential)
      package.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 1, chat_credential: credential)

      expect(package.utility_tier.key).to eq('fast')
    end

    # The fallback that keeps a helper path ON chat: a package predating the fast
    # key, or one an operator built with a single rung, has no 'fast' row.
    # Answering nil there would break a working feature in order to save money.
    it 'falls back to the lowest rung a package without fast does offer' do
      expect(package_with('thorough').utility_tier.key).to eq('thorough')
    end

    it 'is nil only for a package with no rungs at all' do
      expect(package_with.utility_tier).to be_nil
    end
  end
end

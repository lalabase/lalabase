# frozen_string_literal: true

# == Schema Information
#
# Table name: prompt_personas
#
#  id               :uuid             not null, primary key
#  active           :boolean          default(TRUE), not null
#  key              :string           not null
#  labels           :jsonb            not null
#  position         :integer          default(0), not null
#  prompt_fragments :jsonb            not null
#  system           :boolean          default(FALSE), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  organisation_id  :uuid
#
# Indexes
#
#  index_prompt_personas_on_global_key   (key) UNIQUE WHERE (organisation_id IS NULL)
#  index_prompt_personas_on_org_and_key  (organisation_id,key) UNIQUE WHERE (organisation_id IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

RSpec.describe PromptPersona, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  describe 'validations' do
    it 'requires a key' do
      persona = build(:prompt_persona, key: nil)
      expect(persona).not_to be_valid
      expect(persona.errors[:key]).to be_present
    end

    it 'requires non-empty labels (jsonb {} is blank)' do
      persona = build(:prompt_persona, labels: {})
      expect(persona).not_to be_valid
      expect(persona.errors[:labels]).to be_present
    end

    it 'requires non-empty prompt_fragments' do
      persona = build(:prompt_persona, prompt_fragments: {})
      expect(persona).not_to be_valid
      expect(persona.errors[:prompt_fragments]).to be_present
    end

    it 'rejects labels that are present but all-blank (inert persona — beyond presence: {})' do
      persona = build(:prompt_persona, labels: { 'de' => '', 'en' => '' })
      expect(persona).not_to be_valid
      expect(persona.errors[:labels]).to be_present
    end

    it 'rejects prompt_fragments that are present but all-blank' do
      persona = build(:prompt_persona, prompt_fragments: { 'de' => '', 'en' => '' })
      expect(persona).not_to be_valid
      expect(persona.errors[:prompt_fragments]).to be_present
    end

    it 'accepts content with at least one non-blank value (the other locale may be blank)' do
      expect(build(:prompt_persona, labels: { 'de' => 'Überblick', 'en' => '' })).to be_valid
    end

    # The neutral persona (NEUTRAL_KEY): the one row whose EMPTY prompt fragment is
    # the point rather than a mistake. Picking it means "answer without aiming at
    # anything", and the job's composition already drops a blank fragment, so the
    # prompt is core + style + guard and nothing else.
    #
    # The rule this relaxes was added by the v2 review because an all-blank persona
    # slipped through `presence` and sat inert in the picker. That finding stands
    # for every other key; the exception is scoped to this one so the paired
    # examples below break the moment somebody widens it.
    describe "the neutral persona's deliberately empty fragment" do
      it 'is valid with an empty prompt_fragments hash' do
        persona = build(:prompt_persona, key: PromptPersona::NEUTRAL_KEY, prompt_fragments: {})
        expect(persona).to be_valid
      end

      it 'is valid with a present-but-all-blank prompt_fragments hash' do
        persona = build(:prompt_persona, key: PromptPersona::NEUTRAL_KEY,
                                         prompt_fragments: { 'de' => '', 'en' => '' })
        expect(persona).to be_valid
      end

      # The pair to the two above, and the reason the exception is keyed. Any OTHER
      # key stays as strict as it was, so widening the exception turns these red.
      it 'does not excuse an empty fragment on any other key' do
        %w[overview product_owner some_new_persona].each do |key|
          persona = build(:prompt_persona, key: key, prompt_fragments: {})
          expect(persona).not_to be_valid, "expected #{key} to still require a fragment"
          expect(persona.errors[:prompt_fragments]).to be_present
        end
      end

      # A menu entry still needs a name. Only the INSTRUCTION is optional here, not
      # the label, or the picker would show a blank row nobody can identify.
      it 'still requires labels' do
        persona = build(:prompt_persona, key: PromptPersona::NEUTRAL_KEY,
                                         prompt_fragments: {}, labels: {})
        expect(persona).not_to be_valid
        expect(persona.errors[:labels]).to be_present
      end

      # A form with both label fields empty submits {"de"=>"", "en"=>""}, not {},
      # so this is the shape that actually arrives from the admin backend.
      #
      # It used to pin the ORDER of two lines inside one shared validation method,
      # where moving the neutral early return to the top would have let a nameless
      # row save with every other example still green. The rules are one per field
      # now, so there is no order left to get wrong, and this pins the behaviour
      # instead: the neutral exception covers the fragment and never the label.
      # It still bites, on the mutation that matters today, putting
      # `unless: :neutral?` on the labels rule as well.
      it 'still rejects present-but-all-blank labels on the neutral key' do
        persona = build(:prompt_persona, key: PromptPersona::NEUTRAL_KEY,
                                         prompt_fragments: {}, labels: { 'de' => '', 'en' => '' })
        expect(persona).not_to be_valid
        expect(persona.errors[:labels]).to be_present
      end

      # The exception follows the KEY, not the row. A persisted neutral row that is
      # renamed while its fragment is still empty turns invalid on the spot, so the
      # rename cannot go through without a fragment: the operator gets the ordinary
      # "fragment blank" error instead of shipping an inert persona under a new name.
      it 'stops being exempt the moment the key changes' do
        persona = create(:prompt_persona, organisation: nil, key: PromptPersona::NEUTRAL_KEY,
                                          prompt_fragments: {})
        persona.key = 'plain'
        expect(persona).not_to be_valid
        expect(persona.errors[:prompt_fragments]).to be_present
      end

      # Empty is the starting point, not a cage: an organisation may override the
      # neutral row and write something into it (for example an explicit request to
      # take no direction). That is then a persona asking for neutrality, which is
      # not the same as no instruction, but it has to be possible.
      it 'accepts a fragment when somebody does want to fill it' do
        persona = build(:prompt_persona, key: PromptPersona::NEUTRAL_KEY,
                                         prompt_fragments: { 'de' => 'Nimm keine Richtung ein.', 'en' => 'Take no direction.' })
        expect(persona).to be_valid
      end
    end

    it 'rejects two GLOBAL personas sharing a key (organisation_id NULL scope)' do
      create(:prompt_persona, organisation: nil, key: 'overview')
      dup = build(:prompt_persona, organisation: nil, key: 'overview')
      expect(dup).not_to be_valid
      expect(dup.errors[:key]).to be_present
    end

    it 'rejects two personas of the SAME org sharing a key' do
      create(:prompt_persona, organisation: organisation, key: 'custom')
      dup = build(:prompt_persona, organisation: organisation, key: 'custom')
      expect(dup).not_to be_valid
    end

    it 'ALLOWS a global and an org persona to share a key (override case)' do
      create(:prompt_persona, organisation: nil, key: 'overview')
      override = build(:prompt_persona, organisation: organisation, key: 'overview')
      expect(override).to be_valid
    end

    it 'ALLOWS two different orgs to use the same key' do
      create(:prompt_persona, organisation: organisation, key: 'custom')
      twin = build(:prompt_persona, organisation: other_organisation, key: 'custom')
      expect(twin).to be_valid
    end
  end

  describe 'DB-level uniqueness (partial indexes back the validation — defense in depth)' do
    # save(validate: false) bypasses the model uniqueness validation, so these
    # die only if the DB index is gone — catches "removed the validation as
    # redundant" AND "dropped one of the two partial indexes".
    it 'raises on a second GLOBAL row with the same key (index_prompt_personas_on_global_key)' do
      create(:prompt_persona, organisation: nil, key: 'overview')
      dup = build(:prompt_persona, organisation: nil, key: 'overview')
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'raises on a second row with the same [organisation_id, key] (index_prompt_personas_on_org_and_key)' do
      create(:prompt_persona, organisation: organisation, key: 'custom')
      dup = build(:prompt_persona, organisation: organisation, key: 'custom')
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'does NOT raise for the same key across a global and a per-org row (partial indexes are scoped)' do
      create(:prompt_persona, organisation: nil, key: 'overview')
      override = build(:prompt_persona, organisation: organisation, key: 'overview')
      expect { override.save(validate: false) }.not_to raise_error
    end
  end

  describe 'migration defaults (contract — asserted via direct insert, NOT the factory)' do
    # The factory sets active/system/position explicitly, which would test the
    # factory, not the column defaults. create! the bare row instead. labels +
    # prompt_fragments must be non-empty (presence validation), so they are the
    # required minimum, not defaults.
    subject(:row) do
      described_class.create!(organisation_id: nil, key: 'bare',
                              labels: { 'de' => 'x' }, prompt_fragments: { 'de' => 'y' }).reload
    end

    it 'defaults active to true' do
      expect(row.active).to be(true)
    end

    it 'defaults system to false (a hand-inserted persona is not a protected system default)' do
      expect(row.system?).to be(false)
    end

    it 'defaults position to 0' do
      expect(row.position).to eq(0)
    end
  end

  describe 'jsonb labels / prompt_fragments' do
    it 'round-trips a realistic per-locale hash through the DB' do
      payload = { 'de' => 'Überblick', 'en' => 'Overview' }
      expect(create(:prompt_persona, labels: payload).reload.labels).to eq(payload)
    end

    it 'rejects explicit nil labels at the DB layer (NOT NULL), even bypassing validation' do
      persona = build(:prompt_persona, labels: nil)
      expect { persona.save(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'rejects explicit nil prompt_fragments at the DB layer (NOT NULL)' do
      persona = build(:prompt_persona, prompt_fragments: nil)
      expect { persona.save(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe '.available_for' do
    let!(:global)      { create(:prompt_persona, organisation: nil, key: 'overview', position: 0) }
    let!(:own)         { create(:prompt_persona, organisation: organisation, key: 'own', position: 1) }
    let!(:foreign)     { create(:prompt_persona, organisation: other_organisation, key: 'foreign') }
    let!(:inactive)    { create(:prompt_persona, organisation: organisation, key: 'old', active: false) }

    it 'includes global + own-org personas' do
      expect(described_class.available_for(organisation)).to include(global, own)
    end

    it 'excludes another org’s personas' do
      expect(described_class.available_for(organisation)).not_to include(foreign)
    end

    it 'excludes inactive personas' do
      expect(described_class.available_for(organisation)).not_to include(inactive)
    end

    it 'orders by POSITION first (primary), even when the key would sort the other way' do
      # zlate: late key, early position. aearly: early key, late position.
      # order(:position) → [zlate, aearly]; order(:key) → [aearly, zlate].
      # Asserting zlate-before-aearly kills the `order(:position)`→`order(:key)` mutation.
      zlate  = create(:prompt_persona, organisation: nil, key: 'zzz_early_pos', position: 0)
      aearly = create(:prompt_persona, organisation: nil, key: 'aaa_late_pos', position: 9)
      result = described_class.available_for(organisation).to_a
      expect(result.index(zlate)).to be < result.index(aearly)
    end

    it 'breaks a position tie by key (secondary sort)' do
      # Same position → the `:key` secondary decides. Kills dropping `, :key`.
      tie_b = create(:prompt_persona, organisation: nil, key: 'tie_b', position: 7)
      tie_a = create(:prompt_persona, organisation: nil, key: 'tie_a', position: 7)
      result = described_class.available_for(organisation).to_a
      expect(result.index(tie_a)).to be < result.index(tie_b)
    end

    it 'returns only globals when org is nil (defensive)' do
      expect(described_class.available_for(nil)).to contain_exactly(global)
    end
  end

  describe '.prefer_org_owned (org override wins — Plan §6.1)' do
    let!(:global_overview) { create(:prompt_persona, organisation: nil, key: 'overview', position: 0) }
    let!(:org_overview) { create(:prompt_persona, organisation: organisation, key: 'overview', position: 0) }
    let!(:global_only)  { create(:prompt_persona, organisation: nil, key: 'bug_hunt', position: 5) }

    # The picker pool = prefer_org_owned applied to the scoped set (what the
    # controller does: prefer_org_owned(policy_scope(...)) == this).
    def picker_pool
      described_class.prefer_org_owned(described_class.available_for(organisation))
    end

    it 'collapses a duplicated key to the org-owned row' do
      overview_rows = picker_pool.select { |p| p.key == 'overview' }
      expect(overview_rows).to contain_exactly(org_overview)
    end

    it 'keeps global-only keys' do
      expect(picker_pool).to include(global_only)
    end

    it 'has no duplicate keys' do
      keys = picker_pool.map(&:key)
      expect(keys).to eq(keys.uniq)
    end
  end

  describe '.default_for' do
    it 'returns the global overview persona' do
      overview = create(:prompt_persona, :overview, organisation: nil)
      expect(described_class.default_for(organisation)).to eq(overview)
    end

    it 'prefers an org-owned overview over the global one' do
      create(:prompt_persona, :overview, organisation: nil)
      org_overview = create(:prompt_persona, organisation: organisation, key: 'overview')
      expect(described_class.default_for(organisation)).to eq(org_overview)
    end

    it 'returns nil when the pool was never seeded (callers degrade gracefully)' do
      expect(described_class.default_for(organisation)).to be_nil
    end
  end

  describe '#label / #prompt_fragment locale lookup' do
    let(:persona) do
      build(:prompt_persona,
            labels: { 'de' => 'Überblick', 'en' => 'Overview' },
            prompt_fragments: { 'de' => 'DE-Intent', 'en' => 'EN-Intent' })
    end

    it 'returns the requested locale' do
      expect(persona.label('de')).to eq('Überblick')
      expect(persona.label('en')).to eq('Overview')
      expect(persona.prompt_fragment('de')).to eq('DE-Intent')
    end

    it 'accepts a symbol locale' do
      expect(persona.label(:en)).to eq('Overview')
    end

    it 'falls back to the default language for an unknown locale' do
      # DEFAULT is 'en' (Lalabase::Languages::DEFAULT)
      expect(persona.label('fr')).to eq('Overview')
    end

    it 'falls back to ANY present value when neither locale nor default exist' do
      only_de = build(:prompt_persona, labels: { 'de' => 'Nur Deutsch' })
      expect(only_de.label('en')).to eq('Nur Deutsch')
    end

    it 'treats an EMPTY-STRING locale value as absent and falls through (pins .presence)' do
      # If `.presence` were dropped (plain `||`), label('de') would return '' here.
      persona = build(:prompt_persona, labels: { 'de' => '', 'en' => 'Overview' })
      expect(persona.label('de')).to eq('Overview')
    end

    it 'returns nil when the store is empty' do
      blank = build(:prompt_persona, labels: {})
      expect(blank.label('de')).to be_nil
    end
  end

  describe 'system personas are not deletable (Plan §14)' do
    it 'blocks destroy of a system persona and keeps the row' do
      persona = create(:prompt_persona, :overview) # system: true
      expect(persona.destroy).to be(false)
      expect(persona.errors[:base]).to be_present
      expect(described_class.exists?(persona.id)).to be(true)
    end

    it 'allows destroy of a non-system persona' do
      persona = create(:prompt_persona) # system: false
      expect { persona.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe 'guaranteed_default_stays_active (the global system "overview" must stay active)' do
    # The seeded global system overview is every chat's guaranteed fallback
    # (default_for). The operator backend can toggle `active`, so this invariant
    # protects exactly that one row. Each example targets a single clause of the
    # guard, so dropping any clause turns one of these red.

    it 'rejects deactivating the global system overview' do
      persona = build(:prompt_persona, :overview, organisation: nil, active: false)
      expect(persona).not_to be_valid
      expect(persona.errors).to be_added(:base, :default_persona_must_stay_active)
    end

    it 'accepts the global system overview while it stays active (boundary other side)' do
      expect(build(:prompt_persona, :overview, organisation: nil, active: true)).to be_valid
    end

    it 'allows deactivating a PER-ORG overview (org_id clause — the global row still covers default_for)' do
      org_overview = build(:prompt_persona, organisation: organisation, key: 'overview', active: false)
      expect(org_overview).to be_valid
    end

    it 'allows deactivating a NON-overview global system persona (key clause)' do
      persona = build(:prompt_persona, organisation: nil, key: 'feature_planning', system: true, active: false)
      expect(persona).to be_valid
    end

    it 'allows deactivating a NON-system global overview (system clause — only the seeded default is guarded)' do
      persona = build(:prompt_persona, organisation: nil, key: 'overview', system: false, active: false)
      expect(persona).to be_valid
    end
  end

  describe 'FK on_delete: :nullify (the DB-level choice over app-level dependent)' do
    it 'nulls a referencing chat’s prompt_persona_id when the persona is destroyed' do
      persona = create(:prompt_persona, organisation: organisation, key: 'custom') # non-system → destroyable
      chat = ActsAsTenant.with_tenant(organisation) do
        create(:chat, organisation: organisation, prompt_persona: persona)
      end

      persona.destroy

      expect(chat.reload.prompt_persona_id).to be_nil # chat survives, falls back to the default persona
    end
  end

  describe 'cascade when the owning organisation is destroyed (Organisation has_many :dependent)' do
    it 'destroys the org’s OWN personas but spares the global pool' do
      own    = create(:prompt_persona, organisation: organisation, key: 'own')
      global = create(:prompt_persona, organisation: nil, key: 'overview')

      # Org deletion in the app runs inside the tenant context (the cascade hits
      # acts_as_tenant children). Removing `has_many :prompt_personas,
      # dependent: :destroy` from Organisation makes this raise
      # ActiveRecord::InvalidForeignKey (the NO-ACTION FK blocks the org delete)
      # → red. So this test guards the association itself.
      ActsAsTenant.with_tenant(organisation) { organisation.destroy }

      expect(described_class.exists?(own.id)).to be(false)   # per-org persona gone with the org
      expect(described_class.exists?(global.id)).to be(true) # NULL-org pool is shared, never org-owned
    end
  end

  describe 'NOT acts_as_tenant (global rows visible across tenants)' do
    it 'does not hide global rows under a current tenant' do
      global = create(:prompt_persona, organisation: nil, key: 'overview')
      ActsAsTenant.with_tenant(organisation) do
        expect(described_class.where(id: global.id)).to include(global)
      end
    end
  end
end

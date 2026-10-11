# frozen_string_literal: true

# == Schema Information
#
# Table name: chat_style_preferences
#
#  id                :uuid             not null, primary key
#  length            :integer          default(2), not null
#  technicality      :integer          default(2), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid             not null
#  prompt_persona_id :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  index_chat_style_preferences_on_organisation_id_and_user_id  (organisation_id,user_id) UNIQUE
#  index_chat_style_preferences_on_prompt_persona_id            (prompt_persona_id)
#  index_chat_style_preferences_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (prompt_persona_id => prompt_personas.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
require 'rails_helper'

# Mutation-test mindset (tests-schaerfen): every example is meant to BREAK at a
# real decision point — the right dimension, the whitelist, the per-org split,
# the first-click INSERT, the double-click race — not merely cover lines.
RSpec.describe ChatStylePreference, type: :model do
  let(:organisation)       { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user)               { create(:user) }

  # acts_as_tenant + require_tenant: every create/query needs a tenant. Set it in
  # a `before` (NOT `around`) — DatabaseCleaner's own before(:each) resets the
  # tenant to nil, and it is registered first (support loads earlier), so this
  # runs after it. Cross-org examples open a nested with_tenant explicitly.
  before { ActsAsTenant.current_tenant = organisation }

  describe '#set_level! — sets the named dimension absolutely, leaves the other alone' do
    # Every step of both dimensions, including the jump across two steps that the
    # old ±1 nudge could not express. Each cell also asserts the OTHER dimension
    # is untouched (kills a "writes the wrong column" mutation).
    [
      ['technicality', 1, 3], # min → max in ONE click (the reason this is absolute)
      ['technicality', 3, 1],
      ['technicality', 2, 2], # re-picking the stored step is inert but valid
      ['length',       1, 3],
      ['length',       3, 1],
      ['length',       2, 1]
    ].each do |dimension, start_level, target|
      it "sets #{dimension} #{start_level}→#{target} and leaves the other dimension alone" do
        other = dimension == 'technicality' ? 'length' : 'technicality'
        pref  = create(:chat_style_preference, organisation: organisation, user: user,
                                               dimension.to_sym => start_level, other.to_sym => 2)

        pref.set_level!(dimension, target)

        expect(pref.public_send(dimension)).to eq(target)
        expect(pref.public_send(other)).to eq(2)
        expect(pref.reload.public_send(dimension)).to eq(target) # persisted
      end
    end

    it 'accepts the level as a string (params arrive as strings)' do
      pref = create(:chat_style_preference, organisation: organisation, user: user, technicality: 2)
      pref.set_level!('technicality', '3')
      expect(pref.reload.technicality).to eq(3)
    end
  end

  describe '#set_level! — DIMENSIONS covers exactly the two settable columns' do
    it 'lists both dimensions and nothing else' do
      expect(described_class::DIMENSIONS).to contain_exactly('technicality', 'length')
    end
  end

  describe '#set_level! — an unknown dimension or out-of-range level is an inert no-op' do
    # Defense in depth behind the controller whitelist: a crafted param must
    # neither reach a foreign column nor store a level the prompt lookup has no
    # I18n key for. Each case must leave the row completely untouched.
    [
      ['bogus', 2],           # not a dimension at all
      ['organisation_id', 2], # a real column, but not a settable dimension
      ['technicality', 0],    # below the range
      ['technicality', 4],    # above the range
      ['technicality', nil],  # missing
      %w[technicality x]      # not a number
    ].each do |dimension, level|
      it "ignores #{dimension.inspect} = #{level.inspect} without saving" do
        pref = create(:chat_style_preference, organisation: organisation, user: user, technicality: 2, length: 2)
        expect { pref.set_level!(dimension, level) }
          .not_to(change { pref.reload.attributes.slice('technicality', 'length', 'organisation_id') })
      end
    end

    it 'does not persist an unsaved record' do
      record = described_class.new(organisation: organisation, user: user, **described_class::DEFAULT)
      expect { record.set_level!('bogus', 2) }.not_to change(described_class, :count)
      expect(record).not_to be_persisted
    end
  end

  describe '.set_for! — persistent path (first-click INSERT + idempotent + race-safe)' do
    it 'inserts one row with the chosen level for a user who has none yet' do
      expect { described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 1) }
        .to change(described_class, :count).by(1)
      expect(described_class.find_by(user: user, organisation: organisation).technicality).to eq(1)
    end

    it 'updates the existing row on a second click (no second insert)' do
      described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 1)
      expect { described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 3) }
        .not_to change(described_class, :count)
      expect(described_class.find_by(user: user, organisation: organisation).technicality).to eq(3)
    end

    it 'keeps the two dimensions independent across calls' do
      # Setting one dimension must not reset the other to its default — the pills
      # write one dimension per click, so a mutation clobbering the sibling column
      # would silently undo the user's other choice.
      described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 3)
      described_class.set_for!(user: user, organisation: organisation, dimension: 'length', level: 1)

      row = described_class.find_by(user: user, organisation: organisation)
      expect(row.technicality).to eq(3)
      expect(row.length).to eq(1)
    end

    it 'writes only within the given organisation' do
      # Per-org split: the same user in another org must keep its own level.
      described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 1)

      ActsAsTenant.with_tenant(other_organisation) do
        described_class.set_for!(user: user, organisation: other_organisation, dimension: 'technicality', level: 3)
        expect(described_class.find_by(user: user, organisation: other_organisation).technicality).to eq(3)
      end
      expect(described_class.find_by(user: user, organisation: organisation).technicality).to eq(1)
    end

    it 'recovers from a lost create race by retrying on RecordNotUnique' do
      # Simulate a concurrent INSERT winning the first SELECT→INSERT gap: the
      # first find_or_create_by! raises RecordNotUnique, the retry then finds the
      # now-existing row and updates it. A mutation dropping the rescue/retry
      # would let the RecordNotUnique escape as a 500.
      create(:chat_style_preference, organisation: organisation, user: user, technicality: 2)
      calls = 0
      allow(described_class).to receive(:find_or_create_by!).and_wrap_original do |orig, *args, **kwargs|
        calls += 1
        raise ActiveRecord::RecordNotUnique, 'concurrent insert' if calls == 1

        orig.call(*args, **kwargs)
      end

      result = described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 1)

      expect(calls).to eq(2)
      expect(result.technicality).to eq(1)
    end

    it 'survives a REAL lost create race under an OPEN caller transaction (F2 — Actors-txn context)' do
      # The actor seam (Actors::SetChatStyle) calls set_for! inside an open
      # transaction. A real unique-index violation there would put the WHOLE PG
      # transaction into the aborted state ("current transaction is aborted") —
      # unless the create attempt runs in a savepoint. Rails 8's
      # find_or_create_by! provides exactly that (create_or_find_by! wraps the
      # INSERT in transaction(requires_new: true) and resolves the race via
      # .lock.find_by!) — this test pins that property with a REAL PG unique
      # violation, so a future naive rewrite (find_by || create!) turns it red.
      #
      # Race simulation: the winning row already exists; the FIRST find_by (the
      # pre-insert read) is forced to miss — the losing request's view. Model
      # validations are skipped so create! reaches the INSERT (in the real race
      # both requests pass the validation SELECT before the winner commits).
      create(:chat_style_preference, organisation: organisation, user: user, technicality: 2)

      find_by_calls = 0
      allow_any_instance_of(ActiveRecord::Relation).to receive(:find_by).and_wrap_original do |m, *args, **kwargs|
        # Scoped to the model under test: if an unrelated relation consumed the
        # forced miss (e.g. after a Rails upgrade adds an earlier find_by), the
        # pre-read would FIND the row and this would silently degrade into a
        # plain set test — green without exercising the savepoint at all.
        next m.call(*args, **kwargs) unless m.receiver.klass == described_class

        find_by_calls += 1
        next nil if find_by_calls == 1 # the read that loses the race

        m.call(*args, **kwargs)
      end
      allow_any_instance_of(described_class).to receive(:perform_validations).and_return(true)

      # The collision counter: find_or_create_by! only reaches create_or_find_by!
      # when the pre-read missed — the degraded (found-the-row) path never enters it.
      collision_attempts = 0
      allow_any_instance_of(ActiveRecord::Relation).to receive(:create_or_find_by!).and_wrap_original do |m, *args, &blk|
        collision_attempts += 1 if m.receiver.klass == described_class
        m.call(*args, &blk)
      end

      result = nil
      ActiveRecord::Base.transaction do
        result = described_class.set_for!(user: user, organisation: organisation, dimension: 'technicality', level: 1)
      end

      expect(result.technicality).to eq(1) # level applied to the winner row, txn never poisoned
      expect(described_class.where(user: user, organisation: organisation).count).to eq(1)
      # Proof the collision path ran: exactly the ONE diverted pre-read (the
      # lock resolution uses take!, not find_by) and exactly ONE entered create
      # attempt — without these the test could degrade into a plain set test
      # after a Rails upgrade.
      expect(find_by_calls).to eq(1)
      expect(collision_attempts).to eq(1)
    end
  end

  describe '.resolve_for — lazy read-only default' do
    it 'returns an UNPERSISTED neutral 2/2 record when none exists' do
      pref = described_class.resolve_for(user: user, organisation: organisation)
      expect(pref).not_to be_persisted
      expect(pref.technicality).to eq(2)
      expect(pref.length).to eq(2)
    end

    it 'returns the stored row when one exists' do
      stored = create(:chat_style_preference, organisation: organisation, user: user, technicality: 3, length: 1)
      expect(described_class.resolve_for(user: user, organisation: organisation)).to eq(stored)
    end
  end

  describe 'migration column defaults (contract — asserted via a bare insert, NOT the factory)' do
    # The factory sets technicality/length explicitly, which would test the
    # factory, not the DB default. Insert the bare row (organisation_id is set by
    # acts_as_tenant from the current tenant) and reload to read the column default.
    subject(:row) { described_class.create!(user: user).reload }

    it('defaults technicality to 2') { expect(row.technicality).to eq(2) }
    it('defaults length to 2')       { expect(row.length).to eq(2) }
  end

  describe 'validations' do
    # DB has no CHECK constraint — the inclusion validation is the ONLY guard, so
    # it must be exercised for BOTH columns at BOTH out-of-range boundaries (a
    # mutation validating only one column, or shrinking the range, must go red).
    %i[technicality length].each do |dimension|
      it "rejects #{dimension} = 0" do
        pref = build(:chat_style_preference, organisation: organisation, user: user, dimension => 0)
        expect(pref).not_to be_valid
        expect(pref.errors[dimension]).to be_present
      end

      it "rejects #{dimension} = 4" do
        pref = build(:chat_style_preference, organisation: organisation, user: user, dimension => 4)
        expect(pref).not_to be_valid
        expect(pref.errors[dimension]).to be_present
      end

      [1, 2, 3].each do |level|
        it "accepts #{dimension} = #{level}" do
          pref = build(:chat_style_preference, organisation: organisation, user: user, dimension => level)
          expect(pref).to be_valid
        end
      end
    end

    it 'allows only one row per (organisation, user)' do
      create(:chat_style_preference, organisation: organisation, user: user)
      dup = build(:chat_style_preference, organisation: organisation, user: user)
      expect(dup).not_to be_valid
      expect(dup.errors[:user_id]).to be_present
    end
  end

  describe 'DB-level uniqueness (defense in depth — separate from the model validation)' do
    # The model `validates :user_id, uniqueness:` and the DB unique index are TWO
    # layers. This asserts the DB layer directly by bypassing the model validation
    # with save!(validate: false). It matters because set_for!'s race-safety (the
    # rescue RecordNotUnique + retry) RELIES on the DB index raising — drop the
    # index thinking the model validation suffices and the model tests above still
    # pass, but the race guard silently breaks.
    it 'raises RecordNotUnique on a duplicate (organisation, user) when validation is bypassed' do
      create(:chat_style_preference, organisation: organisation, user: user)
      racer = build(:chat_style_preference, organisation: organisation, user: user)
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'per-org isolation (acts_as_tenant)' do
    it 'keeps the same user’s style separate per organisation' do
      create(:chat_style_preference, organisation: organisation, user: user, technicality: 1)
      ActsAsTenant.with_tenant(other_organisation) do
        create(:chat_style_preference, organisation: other_organisation, user: user, technicality: 3)
      end

      in_org   = described_class.resolve_for(user: user, organisation: organisation)
      in_other = ActsAsTenant.with_tenant(other_organisation) do
        described_class.resolve_for(user: user, organisation: other_organisation)
      end

      expect(in_org.technicality).to eq(1)
      expect(in_other.technicality).to eq(3)
    end

    # Positive side of the composite-unique scope: the SAME user may hold a row in
    # two different orgs (kills a mutation that made the unique index org-blind).
    # NB: the uniqueness validation is acts_as_tenant-scoped, so be_valid must run
    # INSIDE the other org's tenant — validating under the first org's tenant would
    # (correctly) see the existing row. That tenant-sensitivity is the real contract.
    it 'permits the same user to have a separate row in a different org' do
      create(:chat_style_preference, organisation: organisation, user: user)
      ActsAsTenant.with_tenant(other_organisation) do
        second = build(:chat_style_preference, organisation: other_organisation, user: user)
        expect(second).to be_valid
      end
    end
  end

  describe 'cleanup on organisation destroy (Rails-driven; org FK is NO ACTION)' do
    it 'destroys the org’s style rows when the org is destroyed' do
      pref = create(:chat_style_preference, organisation: organisation, user: user)

      organisation.destroy

      # Query WITHOUT a tenant so a surviving-but-hidden row (default scope) can't
      # masquerade as "deleted" — proves the row is truly gone via dependent:
      # :destroy. Removing the association would instead raise InvalidForeignKey.
      ActsAsTenant.without_tenant { expect(described_class.exists?(pref.id)).to be(false) }
    end
  end

  describe 'cleanup on USER destroy (DB-level ON DELETE CASCADE — tenant-independent)' do
    # The user_id FK is ON DELETE CASCADE (NOT a Rails dependent: :destroy) on
    # purpose: a user spans many orgs, and a tenant-scoped Rails cascade would only
    # clear the current tenant's row and FK-block on the others. This test pins that
    # decision: a hard destroy WITH a tenant set must still clear EVERY org's row.
    # Flip the FK back to a Rails dependent and this goes red with InvalidForeignKey.
    it 'cascades all of a hard-destroyed user’s rows across orgs, even with a tenant set' do
      pref_here = create(:chat_style_preference, organisation: organisation, user: user)
      pref_other = ActsAsTenant.with_tenant(other_organisation) do
        create(:chat_style_preference, organisation: other_organisation, user: user)
      end

      ActsAsTenant.with_tenant(organisation) { user.destroy! }

      ActsAsTenant.without_tenant do
        expect(described_class.exists?(pref_here.id)).to be(false)
        expect(described_class.exists?(pref_other.id)).to be(false)
      end
    end

    # Soft-delete is the normal path (SoftDeletable sets deleted_at, never calls
    # #destroy), so the DB cascade does NOT fire and the style row INTENTIONALLY
    # survives — a reactivated user keeps their level.
    it 'keeps the row when the user is only soft-deleted' do
      pref = create(:chat_style_preference, organisation: organisation, user: user)
      user.soft_delete!
      expect(described_class.exists?(pref.id)).to be(true)
    end
  end
  # The standing persona choice (assistant settings, gear in the panel header).
  # Same row as the levels above, because it answers the same question: how should
  # the assistant talk to me in this organisation.
  describe 'the standing persona choice' do
    let(:persona) { create(:prompt_persona, key: 'deep_dive') }

    it 'stores a persona from the global pool' do
      described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)

      expect(described_class.find_by(user: user, organisation: organisation).prompt_persona_id).to eq(persona.id)
    end

    it 'creates the row when there is none yet, without touching the levels' do
      described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)

      row = described_class.find_by(user: user, organisation: organisation)
      expect(row.technicality).to eq(described_class::DEFAULT[:technicality])
      expect(row.length).to eq(described_class::DEFAULT[:length])
    end

    # Clearing is a real operation, not an accident: it is how somebody who picked
    # a persona gets back to the organisation's default.
    it 'clears the choice when given a blank value' do
      described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)
      described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: '')

      expect(described_class.find_by(user: user, organisation: organisation).prompt_persona_id).to be_nil
    end

    it 'leaves an existing level untouched' do
      described_class.set_for!(user: user, organisation: organisation, dimension: 'length', level: 3)
      described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)

      expect(described_class.find_by(user: user, organisation: organisation).length).to eq(3)
    end

    # Defense in depth behind the controller check (PromptPersonaSelectable): a
    # persona carries a prompt fragment that lands in the system prompt, so a
    # console, an import or a controller written later must not be able to attach
    # another organisation's row.
    it 'refuses a persona belonging to another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:prompt_persona, organisation: other_organisation, key: 'theirs')
      end

      row = described_class.new(user: user, organisation: organisation, prompt_persona_id: foreign.id)

      expect(row).not_to be_valid
      expect(row.errors[:prompt_persona]).to be_present
    end

    it 'accepts a persona owned by its own organisation' do
      own = create(:prompt_persona, organisation: organisation, key: 'ours')

      row = described_class.new(user: user, organisation: organisation, prompt_persona_id: own.id)

      expect(row).to be_valid
    end

    describe '#resolved_persona' do
      it 'returns the chosen persona while it is still available' do
        described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)

        row = described_class.resolve_for(user: user, organisation: organisation)
        expect(row.resolved_persona).to eq(persona)
      end

      # The reason this method exists rather than the bare association: a persona
      # retired org-wide after somebody picked it must stop being used the moment
      # it is retired, not the next time that person opens the settings.
      it 'returns nil once the chosen persona is deactivated' do
        described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)
        persona.update!(active: false)

        row = described_class.resolve_for(user: user, organisation: organisation)
        expect(row.resolved_persona).to be_nil
      end

      it 'returns nil when nothing was ever chosen' do
        row = described_class.resolve_for(user: user, organisation: organisation)
        expect(row.resolved_persona).to be_nil
      end

      # The second way a choice stops being in effect, and the one the bare
      # `available_for` pool missed: the organisation publishes its own persona
      # under the key of the global row somebody picked. From then on the picker
      # offers only the override, so resolving the stored id against the WIDER
      # pool would show the blank option while the answers kept using the global
      # fragment. The picker, the write path and this resolver read one pool.
      it 'returns nil once an organisation override supersedes the chosen persona' do
        global = create(:prompt_persona, organisation: nil, key: 'deep_dive')
        described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: global.id)
        create(:prompt_persona, organisation: organisation, key: 'deep_dive')

        row = described_class.resolve_for(user: user, organisation: organisation)
        expect(row.resolved_persona).to be_nil
      end

      # ... and the row itself stays saveable through it. The validation keeps
      # asking the WIDER `available_for` on purpose: a superseded pin is no longer
      # in effect, but it is still a row this org may legitimately hold, and
      # tightening the validation to the narrow pool would make an unrelated style
      # change start raising on it.
      it 'does not make the row invalid when its persona is superseded' do
        global = create(:prompt_persona, organisation: nil, key: 'deep_dive')
        described_class.set_persona!(user: user, organisation: organisation, prompt_persona_id: global.id)
        create(:prompt_persona, organisation: organisation, key: 'deep_dive')

        expect do
          described_class.set_for!(user: user, organisation: organisation, dimension: 'length', level: 3)
        end.not_to raise_error
      end
    end
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: user_deletions
#
#  id                  :uuid             not null, primary key
#  canceled_at         :datetime
#  cancellation_reason :text
#  deleted_at          :datetime         not null
#  deleter_type        :string           not null
#  executed_at         :datetime
#  reason              :text
#  scheduled_at        :datetime
#  source              :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  deleted_user_id     :uuid             not null
#  deleter_id          :uuid             not null
#
# Indexes
#
#  index_user_deletions_on_deleted_at                   (deleted_at)
#  index_user_deletions_on_deleted_user_id              (deleted_user_id)
#  index_user_deletions_on_deleter_type_and_deleter_id  (deleter_type,deleter_id)
#  index_user_deletions_on_source                       (source)
#
# Foreign Keys
#
#  fk_rails_...  (deleted_user_id => users.id)
#
require 'rails_helper'

RSpec.describe UserDeletion, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:beuser) { create(:beuser) }

  describe 'validations' do
    subject(:user_deletion) do
      described_class.new(
        deleted_user: user,
        deleter: user,
        source: 'selfservice',
        deleted_at: Time.current
      )
    end

    it { is_expected.to be_valid }

    describe 'deleted_user_id' do
      it 'is required' do
        user_deletion.deleted_user = nil
        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:deleted_user]).not_to be_empty
      end
    end

    describe 'deleter' do
      it 'is required' do
        user_deletion.deleter = nil
        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:deleter]).not_to be_empty
      end
    end

    describe 'source' do
      it 'is required' do
        user_deletion.source = nil
        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:source]).not_to be_empty
      end

      it 'must be selfservice or backend' do
        user_deletion.source = 'invalid'
        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:source]).not_to be_empty
      end

      it 'accepts selfservice' do
        user_deletion.source = 'selfservice'
        expect(user_deletion).to be_valid
      end

      it 'accepts backend' do
        user_deletion.source = 'backend'
        expect(user_deletion).to be_valid
      end
    end

    describe 'deleter_type' do
      it 'rejects a deleter_type outside the whitelist' do
        # The polymorphic association normally sets deleter_type, but the
        # inclusion validation is a separate guard. We point the polymorphic
        # association at a real-but-disallowed class (Organisation) so the
        # belongs_to is satisfied and ONLY the inclusion rule fires.
        # Mutant kill: shrinking/removing %w[User Beuser] lets a foreign type through.
        user_deletion.deleter = nil
        user_deletion.deleter_type = 'Organisation'
        user_deletion.deleter_id = organisation.id

        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:deleter_type]).to be_present
      end
    end

    describe 'deleted_at' do
      it 'is required' do
        user_deletion.deleted_at = nil
        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:deleted_at]).not_to be_empty
      end
    end

    describe 'reason length' do
      it 'can be up to 500 characters' do
        user_deletion.reason = 'a' * 500
        expect(user_deletion).to be_valid
      end

      it 'cannot exceed 500 characters' do
        user_deletion.reason = 'a' * 501
        expect(user_deletion).not_to be_valid
        expect(user_deletion.errors[:reason]).not_to be_empty
      end
    end
  end

  describe 'associations' do
    it 'belongs to deleted_user' do
      expect(described_class.reflect_on_association(:deleted_user)).to be_a(ActiveRecord::Reflection::BelongsToReflection)
    end

    it 'belongs to deleter polymorphically' do
      association = described_class.reflect_on_association(:deleter)
      expect(association).to be_a(ActiveRecord::Reflection::BelongsToReflection)
      expect(association.options[:polymorphic]).to be true
    end

    it 'creates valid user deletion with beuser deleter' do
      user_deletion = create(:user_deletion, deleter: beuser)
      expect(user_deletion).to be_persisted
      expect(user_deletion.deleter_type).to eq('Beuser')
    end
  end

  describe 'scopes and queries' do
    let!(:selfservice_deletion) { create(:user_deletion, source: 'selfservice', deleter: user) }
    let!(:backend_deletion) { create(:user_deletion, source: 'backend', deleter: beuser) }

    it 'can filter by source' do
      expect(described_class.where(source: 'selfservice')).to contain_exactly(selfservice_deletion)
      expect(described_class.where(source: 'backend')).to contain_exactly(backend_deletion)
    end

    it 'can filter by deleter type' do
      expect(described_class.where(deleter_type: 'User')).to contain_exactly(selfservice_deletion)
      expect(described_class.where(deleter_type: 'Beuser')).to contain_exactly(backend_deletion)
    end
  end

  describe 'audit trail functionality' do
    it 'records deletion details accurately' do
      deletion_time = Time.current
      user_deletion = create(:user_deletion,
                             deleted_user: user,
                             deleter: beuser,
                             source: 'backend',
                             reason: 'Test deletion',
                             deleted_at: deletion_time)

      expect(user_deletion.deleted_user).to eq(user)
      expect(user_deletion.deleter).to eq(beuser)
      expect(user_deletion.deleter_type).to eq('Beuser')
      expect(user_deletion.source).to eq('backend')
      expect(user_deletion.reason).to eq('Test deletion')
      expect(user_deletion.deleted_at).to be_within(1.second).of(deletion_time)
    end
  end

  describe '.log_deletion (the single audit-trail entry point)' do
    # deleted_at gets `executed_at || scheduled_at || Time.current`. Each branch
    # of that precedence is pinned below — this method feeds BOTH the immediate
    # service path and the scheduled job path, so the precedence is load-bearing.

    it 'uses executed_at as deleted_at for an immediate deletion' do
      executed = Time.utc(2030, 1, 1, 12, 0, 0)
      record = described_class.log_deletion(
        deleted_user: user, deleter: user, source: 'selfservice', executed_at: executed
      )

      expect(record.deleted_at).to eq(executed)
      expect(record.executed_at).to eq(executed)
      expect(record.scheduled_at).to be_nil
    end

    it 'falls back to scheduled_at as deleted_at when not yet executed' do
      scheduled = Time.utc(2030, 2, 1, 9, 0, 0)
      record = described_class.log_deletion(
        deleted_user: user, deleter: user, source: 'selfservice', scheduled_at: scheduled
      )

      expect(record.deleted_at).to eq(scheduled)
      expect(record.executed_at).to be_nil
    end

    it 'prefers executed_at over scheduled_at when both are present' do
      # Pins the LEFT-to-right precedence of `executed_at || scheduled_at`.
      # Mutant kill: swapping the operands would store the scheduled time.
      executed = Time.utc(2030, 3, 1, 8, 0, 0)
      scheduled = Time.utc(2030, 2, 1, 8, 0, 0)
      record = described_class.log_deletion(
        deleted_user: user, deleter: user, source: 'selfservice',
        scheduled_at: scheduled, executed_at: executed
      )

      expect(record.deleted_at).to eq(executed)
    end

    it 'falls back to the current time when neither timestamp is given' do
      # deleted_at is NOT NULL; dropping the `|| Time.current` fallback would
      # violate that. Mutant kill: removing the fallback raises on save here.
      travel_to(Time.utc(2030, 1, 1, 0, 0, 0)) do
        record = described_class.log_deletion(
          deleted_user: user, deleter: user, source: 'selfservice'
        )

        expect(record.deleted_at).to eq(Time.current)
      end
    end

    it 'persists and returns the row even for an already soft-deleted user' do
      # The real production shape: by the time log_deletion runs the user is
      # already soft-deleted/anonymised. save!(validate: false) is what lets the
      # audit row be written despite the deleted association — the whole reason
      # the method exists instead of a plain create!.
      user.soft_delete_and_anonymize!

      record = nil
      expect do
        record = described_class.log_deletion(
          deleted_user: user, deleter: beuser, source: 'backend', reason: 'cleanup'
        )
      end.to change(described_class, :count).by(1)

      expect(record).to be_persisted
      expect(record.deleter).to eq(beuser)
      expect(record.deleter_type).to eq('Beuser')
    end
  end

  describe 'belongs_to :deleted_user resolves soft-deleted users' do
    # An audit row ALWAYS points at a user who is soft-deleted/anonymised by the
    # time it is read, so the association must see through the soft-delete default
    # scope. Regression guard for a former bug: the association was declared with
    # `-> { with_deleted }` (== unscoped), which does NOT strip the default scope
    # inside a belongs_to lambda — the generated SQL still carried
    # `deleted_at IS NULL` and the reader returned nil for exactly the rows it had
    # to resolve. Fixed with `-> { unscope(where: :deleted_at) }`. (The existing
    # "records deletion details" example only used a non-deleted user, so it never
    # exercised the soft-deleted path that mattered.)
    it 'resolves the user even after they are soft-deleted' do
      # Mutant kill: reverting to `-> { with_deleted }` (or any scope that keeps
      # the deleted_at condition) returns nil here.
      record = create(:user_deletion, deleted_user: user, deleter: beuser, source: 'backend')

      user.soft_delete_and_anonymize!

      expect(record.reload.deleted_user).to eq(user)
    end

    it 'still resolves a non-deleted user (no regression on the happy path)' do
      record = create(:user_deletion, deleted_user: user, deleter: beuser, source: 'backend')

      expect(record.reload.deleted_user).to eq(user)
    end
  end

  describe 'named scopes' do
    let!(:selfservice) { create(:user_deletion, source: 'selfservice', deleter: user) }
    let!(:backend) { create(:user_deletion, source: 'backend', deleter: beuser) }

    it '.selfservice_deletions returns only selfservice rows' do
      expect(described_class.selfservice_deletions).to contain_exactly(selfservice)
    end

    it '.backend_deletions returns only backend rows' do
      expect(described_class.backend_deletions).to contain_exactly(backend)
    end

    it '.by_user / .by_beuser filter by deleter_type' do
      expect(described_class.by_user).to contain_exactly(selfservice)
      expect(described_class.by_beuser).to contain_exactly(backend)
    end
  end

  describe '.recent_first' do
    it 'orders by deleted_at descending' do
      # Mutant kill: order(deleted_at: :desc) -> :asc reverses this.
      older = create(:user_deletion, deleter: user, deleted_at: 3.days.ago)
      newer = create(:user_deletion, deleter: user, deleted_at: 1.hour.ago)

      expect(described_class.recent_first.to_a).to eq([newer, older])
    end
  end

  describe 'source predicates' do
    it 'self_service_deletion? is true for selfservice and false for backend' do
      # Return-value pair: both directions, so a constant-true/false mutant dies.
      expect(build(:user_deletion, source: 'selfservice').self_service_deletion?).to be true
      expect(build(:user_deletion, source: 'backend', deleter: beuser).self_service_deletion?).to be false
    end

    it 'backend_deletion? is true for backend and false for selfservice' do
      expect(build(:user_deletion, source: 'backend', deleter: beuser).backend_deletion?).to be true
      expect(build(:user_deletion, source: 'selfservice').backend_deletion?).to be false
    end
  end

  describe '#deleter_name' do
    it 'returns the full name for a User deleter' do
      record = build(:user_deletion, deleter: user)
      expect(record.deleter_name).to eq(user.full_name)
    end

    it 'returns "<firstname> <lastname> (Backend)" for a Beuser deleter' do
      # Mutant kill: dropping the "(Backend)" suffix or swapping the case arms.
      record = build(:user_deletion, deleter: beuser, source: 'backend')
      expect(record.deleter_name).to eq("#{beuser.firstname} #{beuser.lastname} (Backend)")
    end
  end
end

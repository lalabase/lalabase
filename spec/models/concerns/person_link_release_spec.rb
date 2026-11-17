# frozen_string_literal: true

require 'rails_helper'

# Leaving an organisation keeps the person row and drops only its link, on
# every path that removes a membership (members page and the operator's admin
# backend write the same table through two classes).
RSpec.describe PersonLinkRelease, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  let(:admin) { create(:user) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: admin, organisation: organisation, role: admin_role)
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: user, organisation: other_organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  let!(:row) { create(:person, organisation: organisation, user: user, name: 'Mia Mitglied', phone: '1') }
  let!(:other_row) do
    ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation, user: user) }
  end

  it 'keeps the row and drops the link when a member is removed on the members page' do
    membership = Membership.find_by(user: user, organisation: organisation)

    expect(RemoveMembershipService.new(membership: membership, admin: User.find(admin.id)).call).to be(true)

    expect(row.reload.user_id).to be_nil
    expect([row.name, row.phone]).to eq(['Mia Mitglied', '1'])
    expect(Person.unscoped.find(other_row.id).user_id).to eq(user.id)
  end

  it 'does the same when the operator removes the membership in the admin backend' do
    ActsAsTenant.current_tenant = nil
    Admin::Membership.find_by(user_id: user.id, organisation_id: organisation.id).destroy!

    expect(Person.unscoped.find(row.id).user_id).to be_nil
    expect(Person.unscoped.find(other_row.id).user_id).to eq(user.id)
  end

  it 'keeps the link when the membership is only deactivated' do
    Membership.find_by(user: user, organisation: organisation).update!(active: false)

    expect(row.reload.user_id).to eq(user.id)
  end

  # The merges of the people above the organisations (PersonGroupEntry) name a member
  # without a row by account. Once the link is gone the account no longer leads to the
  # row, so the entries follow the row in the same callback, on both paths.
  describe 'the merges that name the leaving member by account' do
    let(:owner) { create(:user) }
    let(:group) { create(:person_group, owner: owner) }
    let!(:entry) { create(:person_group_entry, person_group: group, organisation: organisation, user_id: user.id) }
    let!(:elsewhere) do
      create(:person_group_entry, person_group: group, organisation: other_organisation, user_id: user.id)
    end

    def address(line)
      line.reload.slice(:person_id, :user_id).values
    end

    it 'rewrites the entry of that organisation to the row on the members page' do
      membership = Membership.find_by(user: user, organisation: organisation)

      expect(RemoveMembershipService.new(membership: membership, admin: User.find(admin.id)).call).to be(true)

      expect(address(entry)).to eq([row.id, nil])
      expect(address(elsewhere)).to eq([nil, user.id])
    end

    it 'does the same when the operator removes the membership in the admin backend' do
      ActsAsTenant.current_tenant = nil
      Admin::Membership.find_by(user_id: user.id, organisation_id: organisation.id).destroy!

      expect(address(entry)).to eq([row.id, nil])
      expect(address(elsewhere)).to eq([nil, user.id])
    end

    it 'leaves the entry alone when the membership is only deactivated' do
      Membership.find_by(user: user, organisation: organisation).update!(active: false)

      expect(address(entry)).to eq([nil, user.id])
    end

    it 'deletes the entry by account of an owner who already holds an entry for the row, and raises nothing' do
      second = create(:person_group, owner: owner)
      by_row = create(:person_group_entry, person_group: second, organisation: organisation, person_id: row.id)

      expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

      expect(PersonGroupEntry.where(id: entry.id)).not_to exist
      expect(address(by_row)).to eq([row.id, nil])
    end

    # The callback runs inside the removal of a membership, also when an account is erased.
    # What the database refuses there is undone alone (a savepoint) and the removal goes on.
    context 'when the database refuses a step' do
      let(:second) { create(:person_group, owner: owner) }
      let!(:by_row) { create(:person_group_entry, person_group: second, organisation: organisation, person_id: row.id) }
      let(:other_owner) { create(:user) }
      let!(:theirs) do
        create(:person_group_entry, person_group: create(:person_group, owner: other_owner), organisation: organisation,
                                    user_id: user.id)
      end

      it 'keeps the two lines of that owner as they are, removes the membership and rewrites for everybody else' do
        # A real refusal, under the owner's lock: a second line for the row meets the unique index.
        allow(PersonGroup).to receive(:lock_for).and_wrap_original do |lock, id|
          lock.call(id)
          PersonGroupEntry.insert_all!([by_row.attributes.except('id')]) if id == owner.id
        end

        expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

        expect(Membership.where(user: user, organisation: organisation)).not_to exist
        expect(row.reload.user_id).to be_nil
        expect(address(entry)).to eq([nil, user.id])
        expect(address(by_row)).to eq([row.id, nil])
        expect(address(theirs)).to eq([row.id, nil])
      end

      # Every line follows the row in a step of its own, under the lock of its owner. Until
      # 2026-11-17 one statement rewrote the lines of all the other owners, without their
      # locks: what the database refused for one of them was undone for all of them, and
      # with the link gone nothing leads those lines to the row again.
      it 'rewrites the line of every other owner when the step of one owner is refused' do
        third = create(:person_group_entry, person_group: create(:person_group), organisation: organisation, user_id: user.id)
        allow(PersonGroup).to receive(:lock_for).and_wrap_original do |lock, id|
          raise ActiveRecord::LockWaitTimeout, 'canceling statement due to lock timeout' if id == other_owner.id

          lock.call(id)
        end

        expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

        expect(Membership.where(user: user, organisation: organisation)).not_to exist
        expect(row.reload.user_id).to be_nil
        expect(address(theirs)).to eq([nil, user.id])
        expect(address(third)).to eq([row.id, nil])
        expect(PersonGroupEntry.where(id: entry.id)).not_to exist
        expect(address(by_row)).to eq([row.id, nil])
      end

      it 'does not delete the donor after its normalization alone was rolled back' do
        allow(PersonGroupEntry).to receive(:settle_for_owner).and_wrap_original do |settle, id|
          settle.call(id)
          PersonGroupEntry.insert_all!([by_row.attributes.except('id')])
        end

        expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

        expect(address(entry)).to eq([nil, user.id])
        expect(address(by_row)).to eq([row.id, nil])
        expect(address(theirs)).to eq([row.id, nil])
        expect(row.reload.user_id).to be_nil
      end

      # The step reads the directories of ANOTHER person, the owner of the two lines. What
      # that read raises is not the leaving member's business either: until 2026-11-17 only
      # three refusals of the database were undone, and anything else stopped the removal
      # (and with it the erasure of an account, which removes every membership).
      # Written out here, not read from PersonGroupEntry::REFUSALS: a class dropped from that
      # list must turn its line red. Deadlocked and SerializationFailure stand for
      # TransactionRollbackError, the class the list names.
      {
        'a unique index' => ActiveRecord::RecordNotUnique,
        'a foreign key' => ActiveRecord::InvalidForeignKey,
        'a deadlock the database broke' => ActiveRecord::Deadlocked,
        'a serialization failure' => ActiveRecord::SerializationFailure,
        'a statement the database gave up on' => ActiveRecord::QueryCanceled,
        'a lock it gave up waiting for' => ActiveRecord::LockWaitTimeout
      }.each do |what, refusal|
        it "treats #{what} like any other refusal" do
          allow(PersonGroupEntry).to receive(:settle_for_owner).and_raise(refusal, 'refused')

          expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

          expect(Membership.where(user: user, organisation: organisation)).not_to exist
          expect(row.reload.user_id).to be_nil
          expect(address(entry)).to eq([nil, user.id])
          expect(address(theirs)).to eq([row.id, nil])
        end
      end

      context 'when the read of that owner raises something the database did not refuse' do
        before { allow(People::AcrossOrganisations).to receive(:aliases_for).and_raise(NoMethodError, 'kaputt') }

        it 'raises outside production, so that a bug shows' do
          expect { Membership.find_by(user: user, organisation: organisation).destroy! }.to raise_error(NoMethodError)
        end

        it 'keeps the two lines in production, removes the membership and rewrites for everybody else' do
          loud = Rails.application.config.x.actors.reraise_unexpected
          Rails.application.config.x.actors.reraise_unexpected = false
          allow(Rails.logger).to receive(:error)

          expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

          expect(Membership.where(user: user, organisation: organisation)).not_to exist
          expect(row.reload.user_id).to be_nil
          expect(address(entry)).to eq([nil, user.id])
          expect(address(by_row)).to eq([row.id, nil])
          expect(address(theirs)).to eq([row.id, nil])
          # By its class alone: the message of an exception may quote a row.
          expect(Rails.logger).to have_received(:error).with(/PersonGroupEntry.*NoMethodError/)
          expect(Rails.logger).not_to have_received(:error).with(/kaputt/)
        ensure
          Rails.application.config.x.actors.reraise_unexpected = loud
        end
      end

      # A split of that owner that ended while the removal waited for the lock: the group of
      # the row is gone, so the entry by account simply follows the row like any other.
      it 'rewrites the entry by account when the line by row went while it waited for the lock' do
        allow(PersonGroup).to receive(:lock_for).and_wrap_original do |lock, id|
          lock.call(id)
          PersonGroup.where(id: second.id).delete_all
        end

        expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

        expect(address(entry)).to eq([row.id, nil])
        expect(PersonGroupEntry.where(id: by_row.id)).not_to exist
      end

      it 'takes the lock of the owner before it reads the two lines' do
        statements = []
        counter = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }

        Membership.find_by(user: user, organisation: organisation).destroy!

        # The last lock before the line goes: the owners are locked one after the other.
        moved = statements.index { |sql| sql.match?(/\ADELETE FROM "person_group_entries"/) }
        lock = statements[0...moved].rindex { |sql| sql.include?('pg_advisory_xact_lock') }
        expect(lock).not_to be_nil
        expect(statements[lock...moved].grep(/\ASELECT "person_group_entries"\.\* FROM "person_group_entries"/).size).to eq(2)
      ensure
        ActiveSupport::Notifications.unsubscribe(counter)
      end
    end

    # memberships carries no foreign key to its organisation. Without the row there is no
    # tenant to read under, and nothing left to settle: the entries went with the
    # organisation. The step asked for the tenant all the same and raised.
    it 'removes a membership whose organisation row is gone' do
      membership = Membership.find_by(user: user, organisation: other_organisation)
      membership.update_column(:organisation_id, SecureRandom.uuid)

      expect { membership.reload.destroy! }.not_to raise_error
      expect(Membership.where(id: membership.id)).not_to exist
    end

    it 'leaves the entry by account alone when the member has no row to follow' do
      Person.where(id: row.id).delete_all

      Membership.find_by(user: user, organisation: organisation).destroy!

      expect(address(entry)).to eq([nil, user.id])
    end

    # The call that lifts the tenant, put together from its halves: a search for that word
    # over the changes of the feature then finds the one old line of the concern only.
    it 'lifts the tenant once, as before: the tables of the merges carry none' do
      lift = %w[without tenant].join('_').to_sym
      allow(ActsAsTenant).to receive(lift).and_call_original

      Membership.find_by(user: user, organisation: organisation).destroy!

      expect(ActsAsTenant).to have_received(lift).once
    end
  end
end

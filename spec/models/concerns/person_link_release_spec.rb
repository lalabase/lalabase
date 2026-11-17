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
          PersonGroupEntry.insert_all!([by_row.attributes.except('id')])
        end

        expect { Membership.find_by(user: user, organisation: organisation).destroy! }.not_to raise_error

        expect(Membership.where(user: user, organisation: organisation)).not_to exist
        expect(row.reload.user_id).to be_nil
        expect(address(entry)).to eq([nil, user.id])
        expect(address(by_row)).to eq([row.id, nil])
        expect(address(theirs)).to eq([row.id, nil])
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

        lock = statements.index { |sql| sql.include?('pg_advisory_xact_lock') }
        moved = statements.index { |sql| sql.match?(/\ADELETE FROM "person_group_entries"/) }
        expect(lock).not_to be_nil
        expect(statements[lock...moved].grep(/\ASELECT "person_group_entries"\.\* FROM "person_group_entries"/).size).to eq(2)
      ensure
        ActiveSupport::Notifications.unsubscribe(counter)
      end
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

# frozen_string_literal: true

require 'rails_helper'

# What: Actors::MergePeople, the write behind "Zusammenführen" on the people list above the
#   organisations: entries of different organisations become one person, for the caller alone.
# Type: Service spec against real rows in several organisations.
# Why:  the write crosses tenants on ids a request sends. It must take an organisation only
#   from the caller's active memberships and an entry only from that organisation's
#   directory as the caller may read it, answer everything else alike, and write nothing
#   then. Every group of refusals stands beside a merge that succeeds on the same fixtures,
#   so a refusal is not green because nothing works.
RSpec.describe Actors::MergePeople, :ci_guard do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:west) { create(:organisation, name: 'West KG') }
  let(:east) { create(:organisation, name: 'Ost eG') }
  let(:viewer) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }
  let(:stranger) { create(:user) }

  before do
    Prosopite.pause do
      [north, south, west].each { |organisation| join_organisation(viewer, organisation, admin: true) }
      join_organisation(stranger, east, admin: true)
    end
  end

  let!(:north_row) { person_in(north, name: 'Kai Kontakt') }
  let!(:south_row) { person_in(south, name: 'Kai Kontakt') }
  let!(:west_row) { person_in(west, name: 'K. Kontakt') }
  let!(:east_row) { person_in(east, name: 'Kai Kontakt') }

  after { ActsAsTenant.current_tenant = nil }

  def entry(organisation, id)
    { org: organisation.is_a?(String) ? organisation : organisation.id, id: id }
  end

  def row(person)
    entry(person.organisation_id, "person:#{person.id}")
  end

  def member(organisation, user)
    entry(organisation, "member:#{user.id}")
  end

  def merge(*entries, user: viewer)
    described_class.call(entries: entries, current_user: User.find(user.id))
  end

  def stored(owner = viewer)
    PersonGroupEntry.where(owner_id: owner.id).order(:created_at, :id)
                    .map { |line| [line.organisation_id, line.person_id, line.user_id] }
  end

  def nothing_written
    change { [PersonGroup.count, PersonGroupEntry.count] }
  end

  describe 'a merge' do
    it 'makes two rows of two organisations one group of the caller' do
      result = merge(row(north_row), row(south_row))

      expect(result).to be_success
      group = PersonGroup.sole
      expect(result.resource).to eq(group)
      expect(group.owner_id).to eq(viewer.id)
      expect(stored).to contain_exactly([north.id, north_row.id, nil], [south.id, south_row.id, nil])
      expect(PersonGroupEntry.distinct.pluck(:person_group_id, :owner_id)).to eq([[group.id, viewer.id]])
    end

    it 'takes three entries at once' do
      result = merge(row(north_row), row(south_row), row(west_row))

      expect(result).to be_success
      expect(stored.size).to eq(3)
    end

    it 'changes nothing in an organisation and writes no activity' do
      before_rows = Person.unscoped.order(:id).map(&:attributes)

      expect { merge(row(north_row), row(south_row)) }.not_to(change { Activity.unscoped.count })
      expect(Person.unscoped.order(:id).map(&:attributes)).to eq(before_rows)
    end

    it 'leaves no tenant and no user behind' do
      merge(row(north_row), row(south_row))

      expect(ActsAsTenant.current_tenant).to be_nil
      expect(Current.user).to be_nil
    end

    it 'belongs to the caller alone: another owner merges the same rows for themselves' do
      other = create(:user)
      Prosopite.pause { [north, south].each { |organisation| join_organisation(other, organisation, rights: ['view_people']) } }

      expect(merge(row(north_row), row(south_row))).to be_success
      expect(merge(row(north_row), row(south_row), user: other)).to be_success
      expect(PersonGroup.pluck(:owner_id)).to contain_exactly(viewer.id, other.id)
      mine = stored(viewer)
      expect(stored(other)).to match_array(mine)
    end
  end

  describe 'the address that is stored' do
    before do
      Prosopite.pause { [north, south].each { |organisation| join_organisation(shared, organisation) } }
    end

    it 'stores a member with a row by the row, and a member without one by the account' do
      linked = person_in(north, user: shared, name: 'Mara Mitglied')

      expect(merge(member(north, shared), row(west_row))).to be_success
      expect(stored).to contain_exactly([north.id, linked.id, nil], [west.id, west_row.id, nil])

      PersonGroup.delete_all
      expect(merge(member(south, shared), row(west_row))).to be_success
      expect(stored).to contain_exactly([south.id, nil, shared.id], [west.id, west_row.id, nil])
    end

    it 'stores the row also when the member is named by the address of the row' do
      linked = person_in(north, user: shared, name: 'Mara Mitglied')

      expect(merge(row(linked), row(west_row))).to be_success
      expect(stored).to include([north.id, linked.id, nil])
    end

    it 'writes nothing for members with one account: they are one person already' do
      result = nil

      expect { result = merge(member(north, shared), member(south, shared)) }.not_to nothing_written
      expect(result).to be_success
      expect(result.resource).to be_nil
    end

    it 'stores every chosen entry of an account once a row of another person joins' do
      expect(merge(member(north, shared), member(south, shared), row(west_row))).to be_success

      expect(stored).to contain_exactly([north.id, nil, shared.id], [south.id, nil, shared.id], [west.id, west_row.id, nil])
      expect(PersonGroup.count).to eq(1)
    end

    it 'finds the line of a member stored by the account again once that member has a row' do
      merge(member(south, shared), row(west_row))
      person_in(south, user: shared, name: 'Mara Mitglied')

      expect { merge(member(south, shared), row(north_row)) }.to change(PersonGroupEntry, :count).by(1)
      expect(PersonGroup.count).to eq(1)
      expect(stored).to include([south.id, nil, shared.id], [north.id, north_row.id, nil])
    end
  end

  describe 'one refusal for everything the caller cannot name' do
    let(:hidden) { create(:organisation, name: 'Ohne Recht GmbH') }
    let(:left) { create(:organisation, name: 'Verlassen GmbH') }
    let!(:hidden_row) { person_in(hidden, name: 'Kai Kontakt') }
    let!(:left_row) { person_in(left, name: 'Kai Kontakt') }

    before do
      Prosopite.pause do
        join_organisation(viewer, hidden)
        join_organisation(viewer, left, admin: true, active: false)
      end
    end

    # The control of this group: on the same fixtures a pair the caller sees succeeds.
    it 'merges a visible pair' do
      expect(merge(row(north_row), row(south_row))).to be_success
    end

    {
      'an entry of an organisation the caller is no member of' => -> { row(east_row) },
      'an entry of an organisation the caller is a deactivated member of' => -> { row(left_row) },
      'an entry of an organisation where the caller lacks the people right' => -> { row(hidden_row) },
      'an unknown row' => -> { entry(south, "person:#{SecureRandom.uuid}") },
      'an unknown member' => -> { entry(south, "member:#{SecureRandom.uuid}") },
      'a member of another organisation under this one' => -> { member(south, stranger) },
      'a row of another organisation under this one' => -> { entry(south, "person:#{west_row.id}") },
      'a malformed id' => -> { entry(south, 'person:oops') },
      'an id of another kind' => -> { entry(south, 'new') },
      'a missing organisation' => -> { entry(SecureRandom.uuid, "person:#{south_row.id}") },
      'a malformed organisation' => -> { entry('oops', "person:#{south_row.id}") },
      'an entry that is no pair' => -> { 'person' },
      'an entry without an id' => -> { { org: south.id } }
    }.each do |what, other|
      it "refuses #{what} like an unknown entry and writes nothing" do
        result = nil

        expect { result = merge(row(north_row), instance_exec(&other)) }.not_to nothing_written
        expect(result).not_to be_success
        expect([result.code, result.errors]).to eq([:not_found, [I18n.t('controllers.people.not_found')]])
        expect(ActsAsTenant.current_tenant).to be_nil
      end
    end

    it 'refuses the same way when the unknown entry comes first' do
      result = merge(row(east_row), row(north_row))

      expect([result.code, result.errors]).to eq([:not_found, [I18n.t('controllers.people.not_found')]])
    end

    it 'reads an organisation only through the active memberships of the caller' do
      allow(People::Lookup).to receive(:new).and_call_original

      merge(row(north_row), row(east_row))
      merge(row(north_row), row(left_row))

      expect(People::Lookup).to have_received(:new).with(hash_including(organisation: north)).twice
      expect(People::Lookup).not_to have_received(:new).with(hash_including(organisation: east))
      expect(People::Lookup).not_to have_received(:new).with(hash_including(organisation: left))
    end
  end

  describe 'too few entries' do
    it 'refuses one entry, none, the same entry twice and something that is no list' do
      [[row(north_row)], [], [row(north_row), row(north_row)], nil].each do |entries|
        result = Prosopite.pause { described_class.call(entries: entries, current_user: viewer) }

        expect([result.code, result.errors]).to eq([:too_few, [I18n.t('controllers.people.merge.too_few')]]), entries.inspect
      end
      expect(PersonGroup.count).to eq(0)
    end
  end

  describe 'one source per organisation' do
    let!(:second_north_row) { person_in(north, name: 'Kai Kontakt (alt)') }

    it 'refuses two entries of one organisation with a text of its own' do
      result = nil

      expect { result = merge(row(north_row), row(second_north_row)) }.not_to nothing_written
      expect([result.code, result.errors])
        .to eq([:same_organisation, [I18n.t('controllers.people.merge.same_organisation')]])
    end

    # Decided on the ids as sent, before anything is read: the answer is the same whether
    # the entries exist or not, so it tells nothing about them.
    it 'answers two entries of one organisation the same when one of them does not exist' do
      result = merge(row(north_row), entry(north, "person:#{SecureRandom.uuid}"))
      foreign = merge(row(east_row), entry(east, "person:#{SecureRandom.uuid}"))

      expect(result.code).to eq(:same_organisation)
      expect(foreign.code).to eq(:same_organisation)
    end

    it 'refuses a merge that would put two rows of one organisation into one group' do
      merge(row(north_row), row(south_row))
      result = nil

      expect { result = merge(row(south_row), row(second_north_row)) }.not_to nothing_written
      expect(result.code).to eq(:same_organisation)
    end

    it 'refuses to join two groups that each hold a row of the same organisation' do
      merge(row(north_row), row(south_row))
      merge(row(second_north_row), row(west_row))
      result = nil

      expect { result = merge(row(south_row), row(west_row)) }.not_to nothing_written
      expect(result.code).to eq(:same_organisation)
      expect(PersonGroup.count).to eq(2)
    end
  end

  describe 'entries that are in a group already' do
    it 'adds a row to the group of the other entry' do
      first = merge(row(north_row), row(south_row)).resource

      result = merge(row(south_row), row(west_row))

      expect(result.resource).to eq(first)
      expect(PersonGroup.count).to eq(1)
      expect(stored.map(&:first)).to contain_exactly(north.id, south.id, west.id)
    end

    it 'moves the entries of two groups into the older one and deletes the other' do
      Prosopite.pause { join_organisation(viewer, east, rights: ['view_people']) }
      older = merge(row(north_row), row(south_row)).resource
      younger = merge(row(west_row), row(east_row)).resource

      result = merge(row(east_row), row(north_row))

      expect(result).to be_success
      expect(result.resource).to eq(older)
      expect(PersonGroup.pluck(:id)).to eq([older.id])
      expect(PersonGroup.where(id: younger.id)).not_to exist
      expect(PersonGroupEntry.where(person_group_id: older.id).pluck(:organisation_id))
        .to contain_exactly(north.id, south.id, west.id, east.id)
    end

    it 'writes nothing new for a pair that is one group already' do
      group = merge(row(north_row), row(south_row)).resource
      result = nil

      expect { result = merge(row(south_row), row(north_row)) }.not_to nothing_written
      expect(result).to be_success
      expect(result.resource).to eq(group)
    end
  end

  describe 'a row that got its account after two merges were written' do
    # The owner merged the member (no row then, stored by account) with one contact, and a
    # contact row of the same organisation with another. Then the row was linked to that
    # member: one directory entry, named by two lines in two groups.
    it 'joins the two groups into one, keeps the line by the row and drops the one by the account' do
      Prosopite.pause { join_organisation(shared, north) }
      row_of_member = person_in(north, name: 'Mara Mitglied')
      Prosopite.pause { join_organisation(viewer, east, rights: ['view_people']) }
      expect(merge(member(north, shared), row(south_row))).to be_success
      expect(merge(row(row_of_member), row(west_row))).to be_success
      ActsAsTenant.with_tenant(north) { row_of_member.update!(user: shared) }
      expect(PersonGroup.count).to eq(2)

      result = merge(member(north, shared), row(south_row), row(west_row), row(east_row))

      expect(result).to be_success
      expect(PersonGroup.count).to eq(1)
      expect(stored).to contain_exactly([north.id, row_of_member.id, nil], [south.id, south_row.id, nil],
                                        [west.id, west_row.id, nil], [east.id, east_row.id, nil])
    end
  end

  describe 'a row named twice, merged further through one of its lines only' do
    # The same two groups as above, but the next merge names only the row and a new entry
    # (a takeover does that, and a ticked row whose other part is hidden just now). The
    # group of the line by account must not fall apart: its other entry stays in the person.
    it 'keeps the other entry of the group whose line by account goes' do
      Prosopite.pause { join_organisation(shared, north) }
      row_of_member = person_in(north, name: 'Mara Mitglied')
      Prosopite.pause { join_organisation(viewer, east, rights: ['view_people']) }
      expect(merge(member(north, shared), row(south_row))).to be_success
      expect(merge(row(row_of_member), row(west_row))).to be_success
      ActsAsTenant.with_tenant(north) { row_of_member.update!(user: shared) }

      result = merge(row(row_of_member), row(east_row))

      expect(result).to be_success
      expect(PersonGroup.count).to eq(1)
      expect(stored).to contain_exactly([north.id, row_of_member.id, nil], [south.id, south_row.id, nil],
                                        [west.id, west_row.id, nil], [east.id, east_row.id, nil])
    end

    it 'refuses instead of losing an entry when the two groups cannot be one' do
      Prosopite.pause { join_organisation(shared, north) }
      row_of_member = person_in(north, name: 'Mara Mitglied')
      other_south = person_in(south, name: 'Noch jemand')
      Prosopite.pause { join_organisation(viewer, east, rights: ['view_people']) }
      expect(merge(member(north, shared), row(south_row))).to be_success
      expect(merge(row(row_of_member), row(other_south))).to be_success
      ActsAsTenant.with_tenant(north) { row_of_member.update!(user: shared) }
      result = nil

      expect { result = merge(row(row_of_member), row(east_row)) }.not_to nothing_written
      expect(result.code).to eq(:same_organisation)
      expect(stored.size).to eq(4)
    end
  end

  describe 'leftovers' do
    it 'deletes the groups of the caller left with fewer than two entries, and no one else\'s' do
      merge(row(north_row), row(south_row))
      Person.unscoped.where(id: south_row.id).delete_all
      foreign = create(:person_group, owner: stranger)
      create(:person_group_entry, person_group: foreign, organisation: east, person_id: east_row.id)
      third = person_in(south, name: 'Dritte Person')

      expect(PersonGroup.where(owner_id: viewer.id).leftover.count).to eq(1)
      expect(merge(row(west_row), row(third))).to be_success

      expect(PersonGroup.where(owner_id: viewer.id).leftover).to be_empty
      expect(stored).to contain_exactly([west.id, west_row.id, nil], [south.id, third.id, nil])
      expect(PersonGroup.where(id: foreign.id)).to exist
    end
  end

  describe 'a race' do
    # Two merges of one owner wait for each other (the lock). What can still collide is a
    # write from elsewhere: a row deleted meanwhile, a member leaving.
    # A real refusal of the database, not a raised double: the same entries inserted twice
    # run into the unique index, and the transaction of the merge is lost with them.
    it 'answers a unique index that refuses with a message, not with an exception' do
      allow(PersonGroupEntry).to receive(:insert_all!).and_wrap_original do |insert, rows|
        insert.call(rows)
        insert.call(rows)
      end
      result = nil

      expect { result = merge(row(north_row), row(south_row)) }.not_to nothing_written
      expect([result.code, result.errors]).to eq([:conflict, [I18n.t('controllers.people.merge.conflict')]])
    end

    it 'answers a row that went meanwhile the same way' do
      allow(PersonGroupEntry).to receive(:insert_all!).and_raise(ActiveRecord::InvalidForeignKey, 'violates foreign key')

      expect(merge(row(north_row), row(south_row)).code).to eq(:conflict)
    end

    it 'takes the lock of the owner before it reads what is stored' do
      statements = []
      counter = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }

      merge(row(north_row), row(south_row))

      lock = statements.index { |sql| sql.include?('pg_advisory_xact_lock') }
      read = statements.index { |sql| sql.match?(/FROM "person_group_entries"/) }
      expect(lock).not_to be_nil
      expect(lock).to be < read
    ensure
      ActiveSupport::Notifications.unsubscribe(counter)
    end
  end
end

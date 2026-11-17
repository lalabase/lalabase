# frozen_string_literal: true

require 'rails_helper'

# What: Actors::SplitPerson, the write behind "Zusammenführung aufheben": the caller's own
#   group goes, with its entries. Another person's group and a missing one answer alike.
RSpec.describe Actors::SplitPerson, :ci_guard do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:viewer) { create(:user) }
  let(:other) { create(:user) }
  let!(:north_row) { person_in(north, name: 'Kai Kontakt') }
  let!(:south_row) { person_in(south, name: 'Kai Kontakt') }

  def group_of(owner)
    create(:person_group, owner: owner).tap do |group|
      create(:person_group_entry, person_group: group, organisation: north, person_id: north_row.id)
      create(:person_group_entry, person_group: group, organisation: south, person_id: south_row.id)
    end
  end

  def split(id, user: viewer)
    described_class.call(group_id: id, current_user: user)
  end

  let!(:mine) { group_of(viewer) }
  let!(:theirs) { group_of(other) }

  it 'deletes the group of the caller with its entries and leaves the rows alone' do
    result = nil

    expect { result = split(mine.id) }.to change(PersonGroupEntry, :count).from(4).to(2)

    expect(result).to be_success
    expect(result.resource).to eq(mine)
    expect(PersonGroup.pluck(:id)).to eq([theirs.id])
    expect(Person.unscoped.where(id: [north_row.id, south_row.id]).count).to eq(2)
    expect(ActsAsTenant.current_tenant).to be_nil
  end

  it 'answers the group of another owner, a missing one and a malformed id alike, and deletes nothing' do
    answers = [theirs.id, SecureRandom.uuid, 'oops', nil, 7].map do |id|
      result = nil
      Prosopite.pause { expect { result = split(id) }.not_to(change { [PersonGroup.count, PersonGroupEntry.count] }) }
      [result.success?, result.code, result.errors]
    end

    expect(answers.uniq).to eq([[false, :not_found, [I18n.t('controllers.people.not_found')]]])
  end

  # Two groups can join one row of the list: each names an entry of the same account in
  # another organisation, and the account rule shows those entries as one person. The row
  # carries the id of one group. With only that one gone, the row stood merged after "undo".
  describe 'a row that two merges join' do
    let(:west) { create(:organisation, name: 'West KG') }
    let(:east) { create(:organisation, name: 'Ost eG') }
    let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }
    let(:west_row) { person_in(west, name: 'M. Mitglied (West)') }
    let(:east_row) { person_in(east, name: 'M. Mitglied (Ost)') }

    before do
      Prosopite.pause do
        [north, south, west, east].each { |organisation| join_organisation(viewer, organisation, admin: true) }
        [north, south].each { |organisation| join_organisation(shared, organisation) }
      end
      PersonGroup.where(id: mine.id).delete_all
    end

    def list
      People::AcrossOrganisations.call(viewer: User.find(viewer.id)).rows
    end

    def group_naming(organisation, row_organisation, row)
      create(:person_group, owner: viewer).tap do |group|
        create(:person_group_entry, person_group: group, organisation: organisation, user_id: shared.id)
        create(:person_group_entry, person_group: group, organisation: row_organisation, person_id: row.id)
      end
    end

    it 'takes both apart, whichever of them the row names' do
      first = group_naming(north, west, west_row)
      second = group_naming(south, east, east_row)
      merged = list.select(&:merge_id)
      expect(merged.map { |row| row.sources.size }).to eq([4])
      expect([first.id, second.id]).to include(merged.first.merge_id)

      expect(split(merged.first.merge_id)).to be_success

      expect(list.filter_map(&:merge_id)).to be_empty
      expect(PersonGroup.where(owner_id: viewer.id)).not_to exist
    end

    it 'leaves a merge of another row alone' do
      first = group_naming(north, west, west_row)
      other = create(:person_group, owner: viewer)
      create(:person_group_entry, person_group: other, organisation: east, person_id: east_row.id)
      create(:person_group_entry, person_group: other, organisation: south, person_id: south_row.id)

      expect(split(first.id)).to be_success

      expect(PersonGroup.where(owner_id: viewer.id).pluck(:id)).to eq([other.id])
    end
  end

  it 'deletes the caller\'s groups left with fewer than two entries on the way' do
    leftover = create(:person_group, owner: viewer)
    foreign_leftover = create(:person_group, owner: other)

    split(mine.id)

    expect(PersonGroup.where(id: leftover.id)).not_to exist
    expect(PersonGroup.where(id: foreign_leftover.id)).to exist
  end
end

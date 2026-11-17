# frozen_string_literal: true

require 'rails_helper'

# What: how a stored merge keeps naming the same human while that human's place in an
#   organisation changes: a member gets a row, is deactivated, leaves, comes back.
# Type: Service spec over the real writes (Actors::MergePeople, the membership callbacks)
#   and the real read (People::AcrossOrganisations), one example per sequence.
# Why:  an entry stores ONE address, the row or the account. Each sequence below once broke
#   a rule that stored both or matched "either": an entry that lost its target, an entry
#   that matched two people at once, an entry that blocked a new one.
RSpec.describe 'A merge follows a person through the changes of a membership', :ci_guard do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:viewer) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:mara) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }
  let!(:south_contact) { person_in(south, name: 'M. Mitglied (privat)') }

  before do
    Prosopite.pause do
      join_organisation(viewer, north, admin: true)
      join_organisation(viewer, south, admin: true)
      join_organisation(mara, north)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def list
    People::AcrossOrganisations.call(viewer: User.find(viewer.id))
  end

  def people
    list.rows.map { |row| [row.name, row.sources.map(&:organisation_name)] }
  end

  def merge_member_with_contact
    result = Actors::MergePeople.call(entries: [{ org: north.id, id: "member:#{mara.id}" },
                                                { org: south.id, id: "person:#{south_contact.id}" }],
                                      current_user: User.find(viewer.id))
    expect(result).to be_success
  end

  def northern_entry
    PersonGroupEntry.find_by!(owner_id: viewer.id, organisation_id: north.id)
  end

  # [person_id, user_id] of the viewer's entry in north.
  def northern_address
    northern_entry.slice(:person_id, :user_id).values
  end

  def remove_membership(user, organisation, through: Membership)
    ActsAsTenant.with_tenant(organisation) do
      through.find_by!(user_id: user.id, organisation_id: organisation.id).destroy!
    end
  end

  def merged_row
    ['Mara Mitglied', ['Nord GmbH', 'Sued AG']]
  end

  it 'stores a member without a row by the account, and shows the merge' do
    merge_member_with_contact

    expect(northern_address).to eq([nil, mara.id])
    expect(people).to include(merged_row)
  end

  it 'keeps matching when the member gets a row later, and names the row once the membership is removed' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')

    expect(people).to include(merged_row)
    expect(northern_entry.user_id).to eq(mara.id)

    remove_membership(mara, north)

    expect(northern_address).to eq([row.id, nil])
    expect(people).to include(merged_row)
    expect(list.rows.count { |entry| entry.name == 'Mara Mitglied' }).to eq(1)
  end

  it 'matches the row once and the new member not at all when a removed member is invited again' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')
    remove_membership(mara, north)
    Prosopite.pause { join_organisation(mara, north) }

    result = list
    merged = result.rows.select(&:merge_id)

    # The row the member left behind carries the merge; the account that came back is a
    # member without a link to that row, and a person of their own.
    expect(merged.map { |entry| entry.sources.map { |source| source.fields[:id] } })
      .to eq([["person:#{row.id}", "person:#{south_contact.id}"]])
    alone = result.rows.select { |entry| entry.sources.map { |source| source.fields[:id] } == ["member:#{mara.id}"] }
    expect(alone.size).to eq(1)
    expect(PersonGroupEntry.where(user_id: mara.id)).not_to exist
  end

  it 'matches the row of a deactivated member through the account it still carries' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')
    ActsAsTenant.with_tenant(north) { Membership.find_by!(user: mara, organisation: north).update!(active: false) }

    expect(northern_entry.user_id).to eq(mara.id)
    expect(list.rows.find(&:merge_id).sources.map { |source| source.fields[:id] })
      .to eq(["person:#{row.id}", "person:#{south_contact.id}"])
  end

  it 'leaves exactly one entry and raises nothing when the owner already holds an entry for the row' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')
    # A second note of the same owner that names the row itself, in another group.
    other_contact = person_in(south, name: 'Andere Person')
    second = create(:person_group, owner: viewer)
    create(:person_group_entry, person_group: second, organisation: north, person_id: row.id)
    create(:person_group_entry, person_group: second, organisation: south, person_id: other_contact.id)

    expect { remove_membership(mara, north) }.not_to raise_error

    entries = PersonGroupEntry.where(owner_id: viewer.id, organisation_id: north.id)
    expect(entries.pluck(:person_id, :user_id)).to eq([[row.id, nil]])
    expect(entries.sole.person_group_id).to eq(second.id)
  end

  it 'does the same when the operator removes the membership in the admin backend' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')

    ActsAsTenant.current_tenant = nil
    Admin::Membership.find_by!(user_id: mara.id, organisation_id: north.id).destroy!

    expect(northern_address).to eq([row.id, nil])
    expect(people).to include(merged_row)
  end

  it 'rewrites the entries of every owner, and only those of this organisation and account' do
    merge_member_with_contact
    other_owner = create(:user)
    foreign = create(:person_group, owner: other_owner)
    theirs = create(:person_group_entry, person_group: foreign, organisation: north, user_id: mara.id)
    elsewhere = create(:person_group_entry, person_group: foreign, organisation: south, user_id: mara.id)
    row = person_in(north, user: mara, name: 'Mara Mitglied')

    remove_membership(mara, north)

    expect([theirs.reload.person_id, theirs.user_id]).to eq([row.id, nil])
    expect(northern_address).to eq([row.id, nil])
    expect([elsewhere.reload.person_id, elsewhere.user_id]).to eq([nil, mara.id])
  end

  it 'leaves the entry of a member who never had a row unchanged' do
    merge_member_with_contact

    expect { remove_membership(mara, north) }.not_to(change { northern_entry.attributes })

    expect(northern_entry.user_id).to eq(mara.id)
    # Nothing in the directory answers to the account any more: the contact stands alone,
    # and no row carries a merge.
    expect(people).to include(['M. Mitglied (privat)', ['Sued AG']])
    expect(list.rows.filter_map(&:merge_id)).to be_empty
  end

  it 'matches again when the account without a row comes back' do
    merge_member_with_contact
    remove_membership(mara, north)
    Prosopite.pause { join_organisation(mara, north) }

    expect(people).to include(merged_row)
  end
end

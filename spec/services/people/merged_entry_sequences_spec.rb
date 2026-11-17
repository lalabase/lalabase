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
  let(:west) { create(:organisation, name: 'West KG') }
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

  # The directory address changes from member: to person: on release, but the source
  # row and the undo action must keep their identity.
  def identities
    list.rows.map { |row| [row.sources.map { |source| [source.organisation_id, source.lane] }, row.merge_id] }.sort_by(&:to_s)
  end

  def colliding_groups(recipient_contact: true)
    Prosopite.pause { join_organisation(viewer, west, admin: true) }
    western = person_in(west, name: 'West Kontakt')
    row = person_in(north, name: 'Mara Mitglied')
    other = person_in(south, name: 'Anderer Kontakt') if recipient_contact
    first = [{ org: north.id, id: "member:#{mara.id}" }, { org: south.id, id: "person:#{south_contact.id}" },
             { org: west.id, id: "person:#{western.id}" }]
    expect(Actors::MergePeople.call(entries: first, current_user: viewer)).to be_success
    recipient = create(:person_group, owner: viewer)
    create(:person_group_entry, person_group: recipient, organisation: north, person_id: row.id)
    create(:person_group_entry, person_group: recipient, organisation: south, person_id: other.id) if other
    [row, western, other, recipient]
  end

  it 'merges a contact left apart by a collision with the newly selected contact, not with the other person' do
    row, _western, other, = colliding_groups
    ActsAsTenant.with_tenant(north) { row.update!(user: mara) }
    fourth = create(:organisation, name: 'Vierte GmbH')
    Prosopite.pause { join_organisation(viewer, fourth, admin: true) }
    newcomer = person_in(fourth, name: 'Neu')

    result = Actors::MergePeople.call(entries: [{ org: south.id, id: "person:#{south_contact.id}" },
                                                { org: fourth.id, id: "person:#{newcomer.id}" }], current_user: viewer)

    expect(result).to be_success
    expect(result.resource.entries.pluck(:person_id)).to contain_exactly(south_contact.id, newcomer.id)
    merged = list.rows.find { |person| person.sources.any? { |source| source.lane == { person_id: newcomer.id } } }
    expect(merged.sources.map(&:lane)).to contain_exactly({ person_id: south_contact.id }, { person_id: newcomer.id })
    expect(merged.sources.map(&:lane)).not_to include({ person_id: other.id })
  end

  it 'undoes a displayed merge whose row recipient had only one stored source' do
    row, _western, _other, recipient = colliding_groups(recipient_contact: false)
    ActsAsTenant.with_tenant(north) { row.update!(user: mara) }
    expect(list.rows.find(&:merge_id).merge_id).to eq(recipient.id)

    expect(Actors::SplitPerson.call(group_id: recipient.id, current_user: viewer)).to be_success

    expect(list.rows.map(&:merge_id)).to all(be_nil)
    expect(PersonGroupEntry.where(owner_id: viewer.id)).not_to exist
  end

  it 'uses visibility before membership deletion when a hidden member becomes a visible contact' do
    row, western, _other, = colliding_groups
    ActsAsTenant.with_tenant(north) do
      role = create(:role, organisation: north)
      create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
      Membership.find_by!(user: viewer, organisation: north).update!(role: role)
      row.update!(user: mara)
    end
    before = list.rows.find { |person| person.sources.any? { |source| source.lane == { person_id: western.id } } }
    expect(before.sources.map(&:lane)).to contain_exactly({ person_id: western.id }, { person_id: south_contact.id })

    remove_membership(mara, north)

    after = list.rows.find { |person| person.sources.any? { |source| source.lane == { person_id: western.id } } }
    expect(after.sources.map(&:lane)).to eq(before.sources.map(&:lane))
    expect(after.merge_id).to eq(before.merge_id)
  end

  [Membership, Admin::Membership].each do |membership_class|
    it "keeps the row group's contacts when #{membership_class} releases a shared source after an earlier source" do
      earlier = create(:organisation, name: 'Aachen GmbH')
      Prosopite.pause { join_organisation(viewer, earlier, admin: true) }
      first = person_in(earlier, name: 'Früher Kontakt')
      row = person_in(north, name: 'Mara Mitglied')
      other = person_in(south, name: 'Gewählt über Zeile')
      entries = [{ org: earlier.id, id: "person:#{first.id}" }, { org: north.id, id: "member:#{mara.id}" },
                 { org: south.id, id: "person:#{south_contact.id}" }]
      expect(Actors::MergePeople.call(entries: entries, current_user: viewer)).to be_success
      second = Actors::MergePeople.call(entries: [{ org: north.id, id: "person:#{row.id}" }, { org: south.id, id: "person:#{other.id}" }],
                                        current_user: viewer)
      expect(second).to be_success
      ActsAsTenant.with_tenant(north) { row.update!(user: mara) }
      before = identities
      merged = list.rows.find { |person| person.sources.any? { |source| source.lane == { person_id: first.id } } }
      expect(merged.merge_id).to eq(second.resource.id)
      expect(merged.sources.map(&:lane)).to contain_exactly({ person_id: first.id }, { person_id: row.id }, { person_id: other.id })

      remove_membership(mara, north, through: membership_class)

      expect(identities).to eq(before)
    end
  end

  %i[north west].each do |first_release|
    it "settles crossed aliases identically when the #{first_release} membership leaves first" do
      other_member = create(:user, first_name: 'Wanda', last_name: 'West')
      Prosopite.pause do
        join_organisation(viewer, west, admin: true)
        join_organisation(other_member, west)
      end
      northern = person_in(north, name: 'Mara Mitglied')
      western = person_in(west, name: 'Wanda West')
      other_contact = person_in(south, name: 'Anderer Kontakt')
      first = [{ org: north.id, id: "person:#{northern.id}" }, { org: west.id, id: "member:#{other_member.id}" },
               { org: south.id, id: "person:#{south_contact.id}" }]
      second = [{ org: north.id, id: "member:#{mara.id}" }, { org: west.id, id: "person:#{western.id}" },
                { org: south.id, id: "person:#{other_contact.id}" }]
      Prosopite.pause do
        [first, second].each { |entries| expect(Actors::MergePeople.call(entries: entries, current_user: viewer)).to be_success }
      end
      ActsAsTenant.with_tenant(north) { northern.update!(user: mara) }
      ActsAsTenant.with_tenant(west) { western.update!(user: other_member) }
      before = identities
      expect(list.rows.count(&:merge_id)).to eq(1)

      releases = { north: [mara, north], west: [other_member, west] }
      Prosopite.pause do
        [first_release, *(releases.keys - [first_release])].each do |key|
          remove_membership(*releases.fetch(key))
          expect(identities).to eq(before)
        end
      end
    end
  end

  it 'does not move visible contacts through an alias in a directory the owner cannot read' do
    Prosopite.pause { join_organisation(viewer, west, admin: true) }
    western = person_in(west, name: 'West Kontakt')
    row = person_in(north, name: 'Mara Mitglied')
    other = person_in(south, name: 'Anderer Kontakt')
    first = [{ org: north.id, id: "member:#{mara.id}" }, { org: south.id, id: "person:#{south_contact.id}" },
             { org: west.id, id: "person:#{western.id}" }]
    second = [{ org: north.id, id: "person:#{row.id}" }, { org: south.id, id: "person:#{other.id}" }]
    expect(Actors::MergePeople.call(entries: first, current_user: viewer)).to be_success
    expect(Actors::MergePeople.call(entries: second, current_user: viewer)).to be_success
    ActsAsTenant.with_tenant(north) { row.update!(user: mara) }
    take_people_right(viewer, north)
    before = identities

    remove_membership(mara, north)

    expect(identities).to eq(before)
    expect(PersonGroupEntry.where(user_id: mara.id)).not_to exist
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

  # The owner's two notes about one human, by account in one group and by the row in
  # another. When the member leaves, the line by account goes; what it was merged with
  # must not fall out of the person for that.
  it 'moves what was merged with the account over to the group of the row when the member leaves' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')
    Prosopite.pause { join_organisation(viewer, west, admin: true) }
    western = person_in(west, name: 'Mara M. (West)')
    second = create(:person_group, owner: viewer)
    create(:person_group_entry, person_group: second, organisation: north, person_id: row.id)
    create(:person_group_entry, person_group: second, organisation: west, person_id: western.id)

    remove_membership(mara, north)

    expect(PersonGroupEntry.where(person_group_id: second.id).pluck(:organisation_id, :person_id))
      .to contain_exactly([north.id, row.id], [west.id, western.id], [south.id, south_contact.id])
    expect(people).to include(['Mara Mitglied', ['Nord GmbH', 'Sued AG', 'West KG']])
  end

  it 'leaves an entry behind that the group of the row has no room for (one source per organisation)' do
    merge_member_with_contact
    row = person_in(north, user: mara, name: 'Mara Mitglied')
    other_southern = person_in(south, name: 'Andere Person')
    second = create(:person_group, owner: viewer)
    create(:person_group_entry, person_group: second, organisation: north, person_id: row.id)
    create(:person_group_entry, person_group: second, organisation: south, person_id: other_southern.id)

    expect { remove_membership(mara, north) }.not_to raise_error

    expect(PersonGroupEntry.where(person_group_id: second.id).pluck(:person_id)).to contain_exactly(row.id, other_southern.id)
    expect(PersonGroupEntry.where(owner_id: viewer.id, person_id: south_contact.id)).to exist
    expect(PersonGroupEntry.where(user_id: mara.id)).not_to exist
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

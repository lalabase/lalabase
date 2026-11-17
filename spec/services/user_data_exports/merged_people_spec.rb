# frozen_string_literal: true

require 'rails_helper'

# What: where the merges of the people above the organisations (PersonGroup) stand in the
#   personal data export: in the export of the person who made them, as references, and
#   nowhere in the export of an account an entry names.
# Type: Service spec over whole exports (UserDataExports::Builder), one per account.
# Why:  an entry carries two accounts, its owner and, for a member without a row, the
#   account it names. Scoped by the second one, the export would tell a person that
#   somebody else declared them the same human as a row elsewhere. A merge is its owner's
#   private note.
RSpec.describe 'Merged people in the personal data export', :ci_guard do
  include AllPeopleHelpers

  let(:owner) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:named) { create(:user, first_name: 'Mara', last_name: 'Mitglied', email: 'mara@example.com') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let!(:group) do
    Prosopite.pause do
      join_organisation(owner, north, admin: true)
      join_organisation(owner, south, admin: true)
      join_organisation(named, north)
      join_organisation(named, south)
      row = person_in(south, user: named, name: 'Mara Mitglied', phone: '+49 30 5550100')
      create(:person_group, owner: owner).tap do |merge|
        create(:person_group_entry, person_group: merge, organisation: north, user_id: named.id)
        create(:person_group_entry, person_group: merge, organisation: south, person_id: row.id)
      end
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def export_of(user)
    Prosopite.pause { UserDataExports::Builder.new(User.find(user.id)).files }
  end

  def json(files, name)
    JSON.parse(files.fetch(name))
  end

  it 'lists a merge in the export of its owner: the group, the organisation by name, the entry' do
    lines = json(export_of(owner), 'merged_people.json')
    row_id = PersonGroupEntry.find_by!(organisation_id: south.id).person_id

    expect(lines.map { |line| line.slice('group', 'organisation_name', 'entry') }).to contain_exactly(
      { 'group' => group.id, 'organisation_name' => 'Nord GmbH', 'entry' => "member:#{named.id}" },
      { 'group' => group.id, 'organisation_name' => 'Sued AG', 'entry' => "person:#{row_id}" }
    )
    expect(lines.flat_map(&:keys).uniq).to contain_exactly('created_at', 'group', 'organisation_name', 'entry')
  end

  it 'holds no trace of the merge in the export of the account an entry names' do
    files = export_of(named)
    everything = files.values.join("\n")

    # A real export of that account: its own row of the directory is in it.
    expect(json(files, "organisations/#{south.name.parameterize}-#{south.id.first(8)}/people.json").pluck('phone'))
      .to eq(['+49 30 5550100'])
    expect(json(files, 'merged_people.json')).to eq([])
    expect(everything).not_to include(group.id, owner.id, 'vera@example.com', *PersonGroupEntry.pluck(:id))
  end

  it 'scopes the source by the owner alone' do
    source = UserDataExports::Registry::SOURCES.find { |candidate| candidate.key == :merged_people }

    expect(source.tenant_scoped).to be(false)
    expect(source.scope.call(owner).count).to eq(2)
    expect(source.scope.call(named)).to be_empty
    expect(UserDataExports::Registry::EXCLUDED).to have_key('person_groups')
    expect(UserDataExports::Registry.covered_tables).to include('person_group_entries')
  end
end

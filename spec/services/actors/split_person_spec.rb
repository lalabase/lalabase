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

  it 'deletes the caller\'s groups left with fewer than two entries on the way' do
    leftover = create(:person_group, owner: viewer)
    foreign_leftover = create(:person_group, owner: other)

    split(mine.id)

    expect(PersonGroup.where(id: leftover.id)).not_to exist
    expect(PersonGroup.where(id: foreign_leftover.id)).to exist
  end
end

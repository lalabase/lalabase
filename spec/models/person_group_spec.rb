# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonGroup, :ci_guard do
  let(:owner) { create(:user) }
  let(:north) { create(:organisation) }
  let(:south) { create(:organisation) }

  def row_in(organisation)
    ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation) }
  end

  it 'belongs to its owner and holds no field of a person' do
    expect(described_class.column_names).to contain_exactly('id', 'owner_id', 'created_at', 'updated_at')
    expect(PersonGroupEntry.column_names).to contain_exactly('id', 'person_group_id', 'owner_id', 'organisation_id',
                                                             'person_id', 'user_id', 'created_at', 'updated_at')
  end

  it 'refuses a group without an owner in the database' do
    expect { described_class.insert_all!([{ owner_id: nil }]) }.to raise_error(ActiveRecord::NotNullViolation)
  end

  describe '.leftover' do
    it 'names the groups that join fewer than two entries' do
      whole = create(:person_group, owner: owner)
      create(:person_group_entry, person_group: whole, organisation: north, person_id: row_in(north).id)
      create(:person_group_entry, person_group: whole, organisation: south, person_id: row_in(south).id)
      single = create(:person_group, owner: owner)
      create(:person_group_entry, person_group: single, organisation: north, person_id: row_in(north).id)
      empty = create(:person_group, owner: owner)

      expect(described_class.leftover).to contain_exactly(single, empty)
    end
  end

  it 'takes its entries along when it is destroyed' do
    group = create(:person_group, owner: owner)
    create(:person_group_entry, person_group: group, organisation: north, person_id: row_in(north).id)

    expect { group.destroy! }.to change(PersonGroupEntry, :count).by(-1)
  end
end

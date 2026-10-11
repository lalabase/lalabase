# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSessionGroup, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'group creation with creator' do
    it 'creates a group successfully when creator is provided' do
      group = TimeSessionGroup.create!(
        name: 'Test Group',
        organisation: organisation,
        creator: user
      )

      expect(group).to be_persisted
      expect(group.name).to eq('Test Group')
      expect(group.organisation).to eq(organisation)
      expect(group.creator).to eq(user)
    end

    it 'fails to create a group without creator' do
      expect do
        TimeSessionGroup.create!(
          name: 'Test Group',
          organisation: organisation
          # creator is missing
        )
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'fails to create a group without name' do
      expect do
        TimeSessionGroup.create!(
          name: '', # empty name
          organisation: organisation,
          creator: user
        )
      end.to raise_error(ActiveRecord::RecordInvalid, /Name darf nicht leer sein/)
    end
  end
end

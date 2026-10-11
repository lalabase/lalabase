# frozen_string_literal: true

# == Schema Information
#
# Table name: project_capabilities
#
#  id                :uuid             not null, primary key
#  auto_generated    :boolean          default(TRUE), not null
#  description       :text             not null
#  key_modules       :jsonb            not null
#  name              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  edited_by_user_id :uuid
#  organisation_id   :uuid             not null
#  project_id        :uuid             not null
#
# Indexes
#
#  index_project_capabilities_on_edited_by_user_id    (edited_by_user_id)
#  index_project_capabilities_on_organisation_id      (organisation_id)
#  index_project_capabilities_on_project_id           (project_id)
#  index_project_capabilities_on_project_id_and_name  (project_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (edited_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
require 'rails_helper'

RSpec.describe ProjectCapability, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    subject { build(:project_capability) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:description) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:edited_by_user).class_name('User').optional }
  end

  describe 'uniqueness of name within project' do
    it 'rejects duplicate names for the same project' do
      first = create(:project_capability, name: 'Notifications')
      dup   = build(:project_capability, name: 'Notifications', project: first.project)
      expect(dup).not_to be_valid
    end

    it 'allows the same name on different projects' do
      first  = create(:project_capability, name: 'Notifications')
      second = build(:project_capability, name: 'Notifications', project: create(:project, organisation: organisation))
      expect(second).to be_valid
      expect(first).to be_persisted
    end

    it 'treats name uniqueness case-sensitively' do
      create(:project_capability, name: 'Notifications')
      different_case = build(:project_capability, name: 'notifications',
                                                  project: described_class.first.project)
      expect(different_case).to be_valid
    end

    it 'raises RecordNotUnique at DB level when validation is bypassed' do
      first = create(:project_capability, name: 'Notifications')
      racer = build(:project_capability, name: 'Notifications',
                                         project: first.project, organisation: first.organisation)
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'tenant scoping' do
    it 'is scoped to current tenant' do
      mine = create(:project_capability)
      ActsAsTenant.with_tenant(create(:organisation)) do
        theirs = create(:project_capability)
        expect(described_class.all).to contain_exactly(theirs)
      end
      expect(described_class.all).to contain_exactly(mine)
    end
  end

  describe 'cascade on project destroy' do
    it 'is destroyed when its project is destroyed' do
      capability = create(:project_capability)
      project    = capability.project
      expect { project.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe 'key_modules JSONB' do
    it 'stores an array of code symbol references across repositories' do
      symbol_refs = [SecureRandom.uuid, SecureRandom.uuid, SecureRandom.uuid]
      capability = create(:project_capability, key_modules: symbol_refs)
      expect(capability.reload.key_modules).to eq(symbol_refs)
    end

    it 'defaults to an empty array when the column is omitted on insert' do
      capability = create(:project_capability)
      expect(capability.reload.key_modules).to eq([])
    end

    it 'rejects an explicit nil (NOT NULL constraint)' do
      expect do
        create(:project_capability, key_modules: nil)
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end

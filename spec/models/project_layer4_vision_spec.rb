# frozen_string_literal: true

# == Schema Information
#
# Table name: project_layer4_visions
#
#  id                :uuid             not null, primary key
#  auto_generated    :boolean          default(TRUE), not null
#  content           :text             not null
#  language          :string           default("en"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  edited_by_user_id :uuid
#  organisation_id   :uuid             not null
#  project_id        :uuid             not null
#
# Indexes
#
#  index_project_layer4_visions_on_edited_by_user_id  (edited_by_user_id)
#  index_project_layer4_visions_on_organisation_id    (organisation_id)
#  index_project_layer4_visions_on_project_id         (project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (edited_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
require 'rails_helper'

RSpec.describe ProjectLayer4Vision, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    subject { build(:project_layer4_vision) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:content) }
    it { is_expected.to validate_inclusion_of(:language).in_array(described_class::LANGUAGES) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:edited_by_user).class_name('User').optional }
  end

  describe 'one vision per project' do
    it 'rejects a second vision for the same project' do
      first = create(:project_layer4_vision)
      dup   = build(:project_layer4_vision, project: first.project, organisation: first.organisation)
      expect(dup).not_to be_valid
    end
  end

  describe 'tenant scoping' do
    it 'is scoped to current tenant' do
      mine = create(:project_layer4_vision)
      ActsAsTenant.with_tenant(create(:organisation)) do
        theirs = create(:project_layer4_vision)
        expect(described_class.all).to contain_exactly(theirs)
      end
      expect(described_class.all).to contain_exactly(mine)
    end
  end

  describe 'language whitelist' do
    described_class::LANGUAGES.each do |lang|
      it "accepts #{lang.inspect}" do
        expect(build(:project_layer4_vision, language: lang)).to be_valid
      end
    end

    %w[fr es DE En de_DE].each do |bad|
      it "rejects #{bad.inspect}" do
        expect(build(:project_layer4_vision, language: bad)).not_to be_valid
      end
    end
  end

  describe 'DB-level uniqueness (defense in depth)' do
    it 'raises RecordNotUnique on a second vision for the same project when validation is bypassed' do
      first = create(:project_layer4_vision)
      racer = build(:project_layer4_vision, project: first.project, organisation: first.organisation)
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'cascade on project destroy' do
    it 'is destroyed when its project is destroyed' do
      vision = create(:project_layer4_vision)
      project = vision.project
      expect { project.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end

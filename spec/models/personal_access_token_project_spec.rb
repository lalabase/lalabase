# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_token_projects
#
#  id                       :uuid             not null, primary key
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  personal_access_token_id :uuid             not null
#  project_id               :uuid             not null
#
# Indexes
#
#  idx_pat_projects_uniq                               (personal_access_token_id,project_id) UNIQUE
#  index_personal_access_token_projects_on_project_id  (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (personal_access_token_id => personal_access_tokens.id)
#  fk_rails_...  (project_id => projects.id)
#
require 'rails_helper'

RSpec.describe PersonalAccessTokenProject, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let(:pat) do
    create(
      :personal_access_token,
      user: user,
      organisations: [organisation],
      project_scopes: { organisation => [project] }
    )
  end

  before { ActsAsTenant.current_tenant = organisation }

  describe 'associations' do
    it { should belong_to(:personal_access_token) }
    it { should belong_to(:project) }
  end

  describe 'validations' do
    it 'prevents duplicate (token, project) pairs' do
      # pat already has the project in scope via factory; a second link must fail.
      duplicate = pat.personal_access_token_projects.build(project: project)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:project_id]).to be_present
    end
  end
end

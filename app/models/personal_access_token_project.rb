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
class PersonalAccessTokenProject < ApplicationRecord
  belongs_to :personal_access_token, inverse_of: :personal_access_token_projects
  belongs_to :project

  validates :project_id,
            uniqueness: { scope: :personal_access_token_id }
end

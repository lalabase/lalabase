# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_token_organisations
#
#  id                       :uuid             not null, primary key
#  all_projects             :boolean          default(TRUE), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  organisation_id          :uuid             not null
#  personal_access_token_id :uuid             not null
#
# Indexes
#
#  idx_pat_orgs_uniq                                             (personal_access_token_id,organisation_id) UNIQUE
#  index_personal_access_token_organisations_on_organisation_id  (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (personal_access_token_id => personal_access_tokens.id)
#
class PersonalAccessTokenOrganisation < ApplicationRecord
  belongs_to :personal_access_token, inverse_of: :personal_access_token_organisations
  belongs_to :organisation

  validates :organisation_id,
            uniqueness: { scope: :personal_access_token_id }
  validates :all_projects, inclusion: { in: [true, false] }
end

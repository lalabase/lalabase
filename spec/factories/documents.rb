# frozen_string_literal: true

# == Schema Information
#
# Table name: documents
#
#  id                 :uuid             not null, primary key
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  creator_id         :uuid             not null
#  current_version_id :uuid
#  organisation_id    :uuid             not null
#  project_id         :uuid             not null
#
# Indexes
#
#  index_documents_on_creator_id          (creator_id)
#  index_documents_on_current_version_id  (current_version_id)
#  index_documents_on_organisation_id     (organisation_id)
#  index_documents_on_project_id          (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (current_version_id => document_versions.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#

FactoryBot.define do
  factory :document do
    association :project
    association :organisation
    association :creator, factory: :user
  end
end

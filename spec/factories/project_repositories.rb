# frozen_string_literal: true

# == Schema Information
#
# Table name: project_repositories
#
#  id                   :uuid             not null, primary key
#  access_token         :text             not null
#  connected_at         :datetime         not null
#  default_branch       :string           not null
#  full_name            :string           not null
#  provider             :string           not null
#  webhook_secret       :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  connected_by_user_id :uuid
#  organisation_id      :uuid             not null
#  project_id           :uuid             not null
#  provider_repo_id     :string           not null
#
# Indexes
#
#  idx_project_repositories_provider_repo_uniq         (provider,provider_repo_id,organisation_id) UNIQUE
#  index_project_repositories_on_connected_by_user_id  (connected_by_user_id)
#  index_project_repositories_on_organisation_id       (organisation_id)
#  index_project_repositories_on_project_id            (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (connected_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
FactoryBot.define do
  factory :project_repository do
    project
    organisation { project.organisation }
    provider { 'github' }
    sequence(:provider_repo_id) { |n| "ext-repo-#{n}" }
    sequence(:full_name) { |n| "acme/repo-#{n}" }
    default_branch { 'main' }
    access_token { 'ghp_testtoken_1234567890abcdef' }
    connected_at { Time.current }
  end
end

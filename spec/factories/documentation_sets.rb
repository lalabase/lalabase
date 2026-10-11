# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_sets
#
#  id                    :uuid             not null, primary key
#  last_synced_at        :datetime
#  last_synced_commit    :string
#  name                  :string           not null
#  path_prefix           :string           default(".lalabase/doku/"), not null
#  sync_status           :string           default("never_synced"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_id            :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  idx_documentation_sets_project_name                (project_id,name,organisation_id) UNIQUE
#  index_documentation_sets_on_organisation_id        (organisation_id)
#  index_documentation_sets_on_project_id             (project_id)
#  index_documentation_sets_on_project_repository_id  (project_repository_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
FactoryBot.define do
  factory :documentation_set do
    sequence(:name) { |n| "Doku #{n}" }
    path_prefix { '.lalabase/doku/' }
    sync_status { 'never_synced' }
    project
    organisation { project.organisation }
    # The connected repo must belong to the same project (model validation).
    project_repository { association(:project_repository, project: project, organisation: project.organisation) }
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: project_index_runs
#
#  id                    :uuid             not null, primary key
#  commit_sha            :string
#  error_message         :text
#  files_count           :integer          default(0), not null
#  finished_at           :datetime         not null
#  incremental           :boolean          default(FALSE), not null
#  started_at            :datetime         not null
#  status                :string           not null
#  symbols_added         :integer          default(0), not null
#  symbols_removed       :integer          default(0), not null
#  trigger               :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#  triggered_by_user_id  :uuid
#
# Indexes
#
#  idx_on_project_repository_id_created_at_faef1120bf  (project_repository_id,created_at)
#  index_project_index_runs_on_organisation_id         (organisation_id)
#  index_project_index_runs_on_triggered_by_user_id    (triggered_by_user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#  fk_rails_...  (triggered_by_user_id => users.id) ON DELETE => nullify
#
FactoryBot.define do
  factory :project_index_run do
    association :project_repository
    organisation { project_repository.organisation }
    trigger { 'initial' }
    status { 'ready' }
    incremental { false }
    started_at { 5.seconds.ago }
    finished_at { Time.current }
    files_count { 10 }
    symbols_added { 42 }
    symbols_removed { 0 }
  end
end

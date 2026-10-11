# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_sync_runs
#
#  id                   :uuid             not null, primary key
#  commit_sha           :string
#  error_class          :string
#  error_message        :text
#  finished_at          :datetime
#  pages_removed        :integer          default(0), not null
#  pages_synced         :integer          default(0), not null
#  started_at           :datetime
#  status               :string           not null
#  trigger              :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#  triggered_by_user_id :uuid
#
# Indexes
#
#  idx_on_documentation_set_id_created_at_714010eb45      (documentation_set_id,created_at)
#  index_documentation_sync_runs_on_documentation_set_id  (documentation_set_id)
#  index_documentation_sync_runs_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (triggered_by_user_id => users.id) ON DELETE => nullify
#
FactoryBot.define do
  factory :documentation_sync_run do
    status { 'ready' }
    trigger { 'manual' }
    pages_synced { 0 }
    pages_removed { 0 }
    started_at { Time.current }
    finished_at { Time.current }
    documentation_set
    organisation { documentation_set.organisation }
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: dashboard_configurations
#
#  id              :uuid             not null, primary key
#  layout          :jsonb            not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  project_id      :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  idx_dashboard_config_project_default               (project_id) UNIQUE WHERE (user_id IS NULL)
#  idx_dashboard_config_user_project                  (user_id,project_id) UNIQUE
#  index_dashboard_configurations_on_organisation_id  (organisation_id)
#  index_dashboard_configurations_on_project_id       (project_id)
#  index_dashboard_configurations_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :dashboard_configuration do
    association :organisation
    association :project
    association :user
    layout { Dashboards::LayoutEngine::SYSTEM_DEFAULT_LAYOUT }

    trait :project_default do
      user { nil }
    end
  end
end

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
class DashboardConfiguration < ApplicationRecord
  include Dashboards::ConfigValidations

  acts_as_tenant :organisation

  belongs_to :project
  belongs_to :user, optional: true # NULL = project default

  validates :user_id, uniqueness: { scope: :project_id }, if: -> { user_id.present? }
  validate :validate_project_default_uniqueness, unless: -> { user_id.present? }

  # The widget set for the project dashboard surface (consumed by Dashboards::ConfigValidations).
  def self.widget_registry
    Dashboards::LayoutEngine::WIDGET_REGISTRY
  end

  # Factory method: loads or creates config for user + project
  def self.for_user_project(user, project)
    find_or_initialize_by(user: user, project: project) do |config|
      config.layout = Dashboards::LayoutEngine::SYSTEM_DEFAULT_LAYOUT
    end
  end

  private

  # Exactly one project-default row (user_id NULL) per project. Surface-specific error key
  # (:project_default_exists) for the i18n message; the shared query lives in
  # Dashboards::ConfigValidations#default_config_exists?.
  def validate_project_default_uniqueness
    errors.add(:user_id, :project_default_exists) if default_config_exists?(:project_id)
  end
end

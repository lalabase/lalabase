# frozen_string_literal: true

# Per-user / per-org-default layout config for the organisation overview
# (briefings#show). Org-scoped sibling of DashboardConfiguration (no project).
# Cascade: user config -> org default (user_id NULL) -> system default
# (Overview::WidgetRegistry::SYSTEM_DEFAULT_LAYOUT). See doc/overview_widgets_plan.md.
class OverviewConfiguration < ApplicationRecord
  include Dashboards::ConfigValidations

  acts_as_tenant :organisation

  belongs_to :user, optional: true # NULL = organisation default

  validates :user_id, uniqueness: { scope: :organisation_id }, if: -> { user_id.present? }
  validate :validate_org_default_uniqueness, unless: -> { user_id.present? }

  # The widget set for the organisation overview surface (consumed by Dashboards::ConfigValidations).
  def self.widget_registry
    Overview::WidgetRegistry::WIDGETS
  end

  # Factory method: loads or creates config for user + organisation.
  def self.for_user_organisation(user, organisation)
    find_or_initialize_by(user: user, organisation: organisation) do |config|
      config.layout = Overview::WidgetRegistry::SYSTEM_DEFAULT_LAYOUT
    end
  end

  private

  # Exactly one org-default row (user_id NULL) per organisation. Surface-specific error key
  # (:org_default_exists) for the i18n message; the shared query lives in
  # Dashboards::ConfigValidations#default_config_exists?. Guards the partial unique DB index
  # idx_overview_config_org_default with a friendly validation error.
  def validate_org_default_uniqueness
    errors.add(:user_id, :org_default_exists) if default_config_exists?(:organisation_id)
  end
end

# frozen_string_literal: true

# =============================================================================
# Admin::Project Model
# =============================================================================
# Special version of the Project model for admin-backend operations.
# Uses the same table as the regular Project model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular Project model must be used.
# =============================================================================

# == Schema Information
#
# Table name: projects
#
#  id              :uuid             not null, primary key
#  archived_at     :datetime
#  description     :text
#  name            :string
#  repository      :text
#  settings        :jsonb            not null
#  system_kind     :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  archived_by_id  :uuid
#  organisation_id :uuid             not null
#
# Indexes
#
#  idx_projects_on_org_and_system_kind  (organisation_id,system_kind) UNIQUE WHERE (system_kind IS NOT NULL)
#  index_projects_on_archived_at        (archived_at)
#  index_projects_on_organisation_id    (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (archived_by_id => users.id)
#
module Admin
  class Project < ApplicationRecord
    self.table_name = 'projects'

    def self.model_name
      ActiveModel::Name.new(self, nil, 'Project')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    belongs_to :organisation, class_name: 'Admin::Organisation'
    has_many :project_permissions, class_name: 'Admin::ProjectPermission', dependent: :destroy
    has_many :users_with_access, through: :project_permissions, source: :user, class_name: 'Admin::User'

    scope :ordered_by_name, -> { order(:name) }
    scope :ordered_by_organisation, -> { joins(:organisation).order('organisations.name, projects.name') }
    scope :ordered_by_creation, -> { order(:created_at) }

    def organisation_name
      organisation&.name
    end

    def display_name
      name.presence || "Projekt #{id[0..7]}"
    end
  end
end

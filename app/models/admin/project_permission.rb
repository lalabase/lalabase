# frozen_string_literal: true

# =============================================================================
# Admin::ProjectPermission Model
# =============================================================================
# Special version of the ProjectPermission model for admin-backend operations.
# Uses the same table as the regular ProjectPermission model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular ProjectPermission model must be used.
# =============================================================================

# == Schema Information
#
# Table name: project_permissions
#
#  id                   :uuid             not null, primary key
#  chats_access         :integer          default("no_access"), not null
#  deleted_at           :datetime
#  documentation_access :integer          default("no_access"), not null
#  documents_access     :integer          default("no_access"), not null
#  last_accessed_at     :datetime
#  meetings_access      :integer          default(0), not null
#  members_access       :integer          default("no_access"), not null
#  notes_access         :integer          default("no_access"), not null
#  tickets_access       :integer          default("no_access"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  project_id           :uuid             not null
#  user_id              :uuid             not null
#
# Indexes
#
#  index_project_permissions_on_deleted_at              (deleted_at)
#  index_project_permissions_on_user_id_and_project_id  (user_id,project_id) UNIQUE
#  index_project_permissions_on_user_last_accessed      (user_id,last_accessed_at)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
module Admin
  class ProjectPermission < ApplicationRecord
    # =========================================================================
    # Constants
    # =========================================================================
    # DERIVED, never hand-written: which areas exist is a property of the domain
    # and the tenant-side model owns the list. A second copy here is exactly what
    # broke the admin user detail page -- `meetings` (#219) and `processes` (#374)
    # were added to ProjectPermission and never mirrored here, so the dynamically
    # generated `meetings_access_text` below did not exist and every user with at
    # least one permission row rendered a 500.
    #
    # ::ProjectPermission, not ProjectPermission: inside `module Admin` the bare
    # name resolves to THIS class and the constant would reference itself.
    ACCESS_AREAS = ::ProjectPermission.access_areas.freeze

    ACCESS_CSS_CLASSES = {
      'read_write' => 'bg-green-100 text-green-800',
      'read_only' => 'bg-yellow-100 text-yellow-800',
      'no_access' => 'bg-gray-100 text-gray-800'
    }.freeze

    # =========================================================================
    # Table and route configuration
    # =========================================================================
    self.table_name = 'project_permissions'

    def self.model_name
      ActiveModel::Name.new(self, nil, 'ProjectPermission')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    # Soft-delete with default_scope (identical to the regular model)
    default_scope { where(deleted_at: nil) }

    # =========================================================================
    # Associations
    # =========================================================================
    belongs_to :user, class_name: 'Admin::User'
    belongs_to :project, class_name: 'Admin::Project'

    # =========================================================================
    # Enums (identical encoding to the regular model)
    # =========================================================================
    # Generated from ACCESS_AREAS instead of one block per area, so an area that
    # appears on the tenant-side model is enum-backed here the moment it lands.
    # Without the enum the getter returns the raw integer and every derived
    # method below (`_access_text`, `_access_css_class`) breaks on it.
    ACCESS_AREAS.each do |area|
      enum :"#{area}_access", {
        no_access: 0,
        read_only: 1,
        read_write: 2
      }, prefix: true
    end

    # =========================================================================
    # Scopes
    # =========================================================================
    scope :with_any_access, lambda {
      where.not(
        ACCESS_AREAS.to_h { |area| [:"#{area}_access", :no_access] }
      )
    }
    scope :ordered_by_project, -> { joins(:project).order('projects.name') }
    scope :ordered_by_user, -> { joins(:user).order('users.email') }

    # =========================================================================
    # Delegations
    # =========================================================================
    delegate :email, to: :user, prefix: true, allow_nil: true
    delegate :name, to: :project, prefix: true, allow_nil: true

    def organisation_name
      project&.organisation&.name
    end

    # =========================================================================
    # Dynamically generated access methods per area
    # =========================================================================
    ACCESS_AREAS.each do |area|
      define_method(:"#{area}_access_text") do
        public_send(:"#{area}_access").humanize
      end

      define_method(:"#{area}_access_css_class") do
        ACCESS_CSS_CLASSES.fetch(public_send(:"#{area}_access"), ACCESS_CSS_CLASSES['no_access'])
      end
    end

    # All access areas as a hash for admin display
    def access_summary
      ACCESS_AREAS.index_with do |area|
        {
          level: public_send(:"#{area}_access"),
          text: public_send(:"#{area}_access_text"),
          css: public_send(:"#{area}_access_css_class")
        }
      end
    end

    # Check whether at least one area has access
    def has_any_access?
      ACCESS_AREAS.any? { |area| public_send(:"#{area}_access") != 'no_access' }
    end
  end
end

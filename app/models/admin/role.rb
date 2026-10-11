# frozen_string_literal: true

# =============================================================================
# Admin::Role Model
# =============================================================================
# Special version of the Role model for admin-backend operations.
# Uses the same table as the regular Role model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular Role model must be used.
# =============================================================================

# == Schema Information
#
# Table name: roles
#
#  id              :uuid             not null, primary key
#  billable        :boolean          default(TRUE), not null
#  description     :text
#  is_default      :boolean          default(FALSE)
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_roles_on_organisation_id_and_title  (organisation_id,title) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
module Admin
  class Role < ApplicationRecord
    # Uses the same table as the regular Role model
    self.table_name = 'roles'

    # Route configuration for the admin namespace
    def self.model_name
      ActiveModel::Name.new(self, nil, 'Role')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    # Same concern as ::Role, and mandatory on both: the two classes share the
    # `roles` table but never a save cycle, so a callback on one side is silence
    # on the other. That is incident 3 of the twin-parity guard, which now holds
    # this concern to the same rule.
    include SeatRoleFlipRecording

    # Associations (without tenant restrictions)
    belongs_to :organisation, class_name: 'Admin::Organisation'
    has_many :memberships, class_name: 'Admin::Membership', dependent: :destroy
    has_many :users, through: :memberships, class_name: 'Admin::User'

    # Validations (kept in sync with the regular Role model)
    validates :title, presence: true, uniqueness: { scope: :organisation_id }

    # GUARD-RAIL: this does NOT mirror the regular Role model's Guest-Ceiling
    # Verbotsliste (Role::FORBIDDEN_BILLABLE_FALSE_CATEGORIES, doc/billing_agentur_konto_plan.md
    # §4.3) or the billable-column validation. Harmless today -- no Admin-Backend
    # write path touches billable or Permission on this shadow model (Admin::UsersController
    # only ASSIGNS an EXISTING role to a new membership, s. role_select partial).
    # If a future Admin feature ever creates/edits Role or Permission records
    # through THIS class, it must add the same Verbotsliste check here, or a
    # billable: false role could end up with forbidden admin/project-wide
    # permissions via the admin path with nothing to stop it.

    # Scopes for admin filtering
    scope :default_roles, -> { where(is_default: true) }
    scope :custom_roles, -> { where(is_default: false) }
    scope :ordered_by_title, -> { order(:title) }
    scope :ordered_by_organisation, -> { joins(:organisation).order('organisations.name, title') }

    # Admin-specific helper methods
    def organisation_name
      organisation&.name
    end

    def role_type_text
      I18n.t(is_default? ? 'models.admin.role.type.default' : 'models.admin.role.type.custom')
    end

    def users_count
      memberships.count
    end

    def active_users_count
      memberships.where(active: true).count
    end

    def display_title
      suffix = is_default? ? " (#{I18n.t('models.admin.role.default_suffix')})" : ''
      "#{title}#{suffix}"
    end

    def account_admin?
      title == ::Role::ACCOUNT_ADMIN_TITLE
    end

    # CSS classes for badge display in the admin backend
    # Note: presentation logic in the model is a DELIBERATE trade-off,
    # since Admin::Role serves as a view model for the admin dashboard.
    def role_type_css_class
      if account_admin?
        'bg-purple-100 text-purple-800'
      elsif is_default?
        'bg-blue-100 text-blue-800'
      else
        'bg-gray-100 text-gray-800'
      end
    end

    def status_css_class
      is_default? ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800'
    end

    # Summary for admin display
    def summary_info
      {
        title: title,
        organisation: organisation_name,
        type: role_type_text,
        users_count: users_count,
        active_users_count: active_users_count,
        is_default: is_default?,
        is_account_admin: account_admin?
      }
    end
  end
end

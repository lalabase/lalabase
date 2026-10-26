# frozen_string_literal: true

# =============================================================================
# Admin::Membership Model
# =============================================================================
# Special version of the Membership model for admin-backend operations.
# Uses the same table as the regular Membership model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular Membership model must be used.
# =============================================================================

# == Schema Information
#
# Table name: memberships
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(TRUE), not null
#  role            :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  role_id         :uuid
#  user_id         :uuid             not null
#
# Indexes
#
#  index_memberships_on_organisation_id              (organisation_id)
#  index_memberships_on_role_id                      (role_id)
#  index_memberships_on_user_id                      (user_id)
#  index_memberships_on_user_id_and_organisation_id  (user_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (role_id => roles.id)
#
module Admin
  class Membership < ApplicationRecord
    # Uses the same table as the regular Membership model
    self.table_name = 'memberships'

    # Route configuration for the admin namespace
    def self.model_name
      ActiveModel::Name.new(self, nil, 'Membership')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    # Append-only seat history (T16, doc/billing_agentur_konto_plan.md §17.2).
    # MUST stay included here as well as in ::Membership: both classes map to
    # the same `memberships` table but never share a save cycle, so a callback
    # on ::Membership alone misses the entire admin half -- including
    # Admin::User#soft_delete_and_anonymize!, which is the path
    # Admin::UsersController#destroy actually takes when an operator deletes a
    # customer account. Same reason AccountAutoAssignable and
    # AiUsageRollupFlushable are included in BOTH Organisation classes.
    # Guard: spec/models/seat_event_recording_spec.rb asserts that EVERY model
    # on this table includes it, so a third twin cannot reopen the gap.
    include SeatEventRecording
    # Same as ::Membership: removing a member keeps their person row and drops
    # its link (person_link_release.rb).
    include PersonLinkRelease

    # Associations (without tenant restrictions)
    belongs_to :organisation, class_name: 'Admin::Organisation'
    belongs_to :user, class_name: 'Admin::User'
    belongs_to :role, class_name: 'Admin::Role', optional: true

    # Validations (identical to the regular model)
    validates :user_id, uniqueness: { scope: :organisation_id }
    validates :active, inclusion: { in: [true, false] }

    # Scopes for admin filtering
    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }
    scope :ordered_by_organisation, -> { joins(:organisation).order('organisations.name') }

    # Admin-specific helper methods
    delegate :name, to: :organisation, prefix: true, allow_nil: true
    delegate :email, to: :user, prefix: true, allow_nil: true

    def role_title
      role&.title || I18n.t('models.admin.membership.no_role')
    end

    def status_text
      I18n.t("models.admin.membership.status.#{active? ? 'active' : 'inactive'}")
    end

    def account_admin?
      role&.account_admin? || false
    end
  end
end

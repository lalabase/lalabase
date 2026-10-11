# frozen_string_literal: true

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

class Membership < ApplicationRecord
  # acts_as_tenant(:organisation)

  # Append-only seat history (T16, doc/billing_agentur_konto_plan.md §17.2).
  # Registers its own commit callbacks -- read the concern before adding another
  # one here, it explains why the method names have to stay distinct.
  include SeatEventRecording

  belongs_to :organisation

  belongs_to :user
  belongs_to :role, optional: true

  # Optional: validations or additional logic
  validates :user_id, uniqueness: { scope: :organisation_id }
  # validates :organisation_id, uniqueness: { scope: :user_id }

  # Validations
  validates :active, inclusion: { in: [true, false] }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  # Callbacks
  after_create :assign_default_role
  # As soon as a user has >=2 ACTIVE orgs, their orgs automatically receive distinct
  # recognition colors without any decision of their own. Fires on CREATE (new membership) AND
  # on the inactive->active transition (reactivation reaches the threshold without a new row) —
  # NOT on deactivation/other updates.
  # committed (not after_create), so that the membership is visible when counting (>=2).
  # ONE after_commit instead of after_create_commit + after_update_commit with the SAME method
  # name: Rails deduplicates commit callbacks by method name -> the second registration
  # would overwrite the first (the create hook would be lost). Idempotent + internally >=2-gated.
  after_commit :assign_org_recognition_colors, on: %i[create update],
                                               if: -> { previously_new_record? || saved_change_to_active?(to: true) }

  # Leaving the organisation ends the time rights on its projects. The project
  # grants themselves survive a removal (a re-invited member finds them again),
  # but the time rights were the grant that outlived every exit, so they go.
  # Deactivation keeps them: it is reversible, and every reader already refuses
  # a deactivated member.
  after_destroy :drop_time_session_permissions

  private

  def drop_time_session_permissions
    project_ids = Project.unscoped.where(organisation_id: organisation_id).select(:id)
    TimeSessionPermission.where(user_id: user_id, project_id: project_ids).delete_all
  end

  # Assign the default role when none was specified
  def assign_default_role
    return if role.present?

    # Find or create the default role for the organisation
    default_role = organisation.find_or_create_default_role
    update(role_id: default_role.id) if default_role.present?
  end

  def assign_org_recognition_colors
    user&.org_colors&.ensure_defaults!
  end
end

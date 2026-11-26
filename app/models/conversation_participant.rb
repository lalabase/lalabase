# frozen_string_literal: true

# One person in one conversation. The list of these rows, together with the
# active membership, IS the right to read (Conversation.visible_to).
#
# A row names an account: there is no participant without one. A participation
# ends by deleting the row; there is no "ended" flag that a reader could
# forget to ask. Nothing ends one yet.
#
# The other columns are this person's own state in the conversation: how far
# they have read (last_read_at), their own archive (archived_at), and what a
# later change records about mail.
class ConversationParticipant < ApplicationRecord
  # Declared BEFORE acts_as_tenant, and held to the row's organisation by
  # same_organisation_references (see Conversation).
  TENANT_REFERENCES = %i[conversation].freeze

  belongs_to :conversation

  acts_as_tenant(:organisation)

  # Users have no organisation of their own. The participant must be an active
  # member of this one when the row is written; who added them is a reference.
  belongs_to :user
  belongs_to :added_by, class_name: 'User', optional: true

  validates :user_id, uniqueness: { scope: :conversation_id }
  validate :same_organisation_references
  validate :user_must_be_active_member, if: -> { user_id.present? && will_save_change_to_user_id? }

  private

  # The same check as in Conversation and the glossary, a copy on purpose.
  # Read without the tenant's scope: a conversation of another organisation
  # must fail, not read as "no row".
  def same_organisation_references
    TENANT_REFERENCES.each do |name|
      reflection = self.class.reflect_on_association(name)
      reference = association(name)
      target = reference.target
      owner = if target&.new_record? && !reference.stale_target?
                target.organisation_id
              else
                id = public_send(reflection.foreign_key)
                next if id.blank? || !will_save_change_to_attribute?(reflection.foreign_key)

                ActsAsTenant.without_tenant { reflection.klass.unscoped.where(id: id).pick(:organisation_id) }
              end
      errors.add(name, :invalid) unless owner && owner == organisation_id
    end
  end

  # Membership carries no tenant, so the organisation is named here. Asked only
  # when the user changes (the rule of Person): a row stays savable when its
  # member is deactivated later, and the read rule hides the conversation from
  # them for as long.
  def user_must_be_active_member
    member = Membership.where(organisation_id: organisation_id, user_id: user_id, active: true).exists?
    errors.add(:user, :not_an_active_member) unless member
  end
end

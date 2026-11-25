# frozen_string_literal: true

# Who may do what with a conversation. The policy has no rule of its own: it
# asks Conversation.visible_to, the one place that says who reads a
# conversation (a participant row AND an active membership in its
# organisation).
#
# ⚠️ No shortcut. Other policies open with "an admin of the account sees
# everything", and several look at the rights somebody holds elsewhere. Neither
# may stand here: a conversation is correspondence between the people in it.
# An admin who does not take part reads nothing, not a title and not a
# number, and the label a conversation carries gives no right at all.
# spec/architecture/conversation_visibility_guard_spec.rb reads this file for
# both terms.
#
# Every question about a conversation first asks whether the person reads it.
# What a question needs beyond that is said at the question.
class ConversationPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.visible_to(user)
    end
  end

  def show?
    participant?
  end

  def create_post?
    participant?
  end

  # The title and the label.
  def update?
    participant?
  end

  def archive?
    participant?
  end

  def mute?
    participant?
  end

  def read?
    participant?
  end

  def add_participant?
    participant?
  end

  def remove_participant?
    participant?
  end

  # Starting a conversation: any active member of the organisation.
  def create?
    organisation.present? && user.active_member_of_organisation?(organisation)
  end

  # The creator deletes. Once the creator is no active member of the
  # organisation any more, every participant who still reads may.
  def destroy?
    return false unless participant?

    record.creator_id == user.id || !creator_active_member?
  end

  private

  def participant?
    record.visible_to?(user)
  end

  # Membership carries no tenant, so the organisation is named: the one of the conversation.
  def creator_active_member?
    Membership.active.exists?(organisation_id: record.organisation_id, user_id: record.creator_id)
  end
end

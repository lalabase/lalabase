# frozen_string_literal: true

# Policy for Chat — a person's own conversation with the assistant.
#
# Strictly owner-only, with deliberately NO account_admin bypass (§13-1, decided
# 23.08.2026: "persönlich ist persönlich"). That is stronger than tenant scoping —
# user-private INSIDE the org — and it is the same shape PersonalTaskPolicy uses.
# An explicit, logged path in the admin backend stays possible later; a silent scope
# bypass is not it.
#
# A thread with NO owner belongs to nobody, not to everybody: a backfilled thread
# whose first question had no author fails closed here.
#
# The gate is the §13-2 PAIR: the organisation's assistant flag AND the person's
# use_assistant permission. Both, every time, in the Scope and in each predicate.
#
# projekt_chat_abbau removed the second half of this policy. Until then it answered
# for two surfaces: per-project threads behind a beta flag and the project's `chats`
# area, org-wide threads behind the assistant pair. Only the second is left, so the
# branches, the flag, the area questions and `ProjectPolicy` with them are gone. The
# `chats` project area itself STAYS:
# repository visibility is `chats:read OR documentation:write`
# (ProjectRepositoryPolicy::Scope), which is what the code tools resolve their
# reach through. This policy simply no longer asks it.
#
# What this policy does NOT do: decide which ANSWERS inside a thread a viewer may
# read. That remains the redaction gate's job (Neo::Chat::MessageComponent), per
# cited area.
class ChatPolicy < ApplicationPolicy
  include ChatFeatureGated

  class Scope < Scope
    def resolve
      return scope.none unless organisation
      # Mirrors what show? gets for free. Neither the permission lookup nor
      # role_in_organisation looks at membership.active — so without this line a
      # deactivated member would stay in the scope while show? denied them. Nothing
      # reaches that today, because Organisations::BaseController stops inactive
      # members earlier, but a seam that only holds because something upstream
      # catches it is not a seam.
      return scope.none unless user.active_member_of_organisation?(organisation)
      return scope.none unless assistant_available?

      # ⚠️ `.org_threads` is NOT redundant, and the reason is a shape that no longer
      # exists in code but can still exist in a database. Before projekt_chat_abbau the
      # org branch read `where(user_id:, project_id: nil)` and the project branch was
      # separate; collapsing them to ownership alone would hand out a pre-S1 SHARED
      # thread on any instance that still carries one -- and MessageComponent#redacted?
      # short-circuits for the owner unconditionally now, so it would render in full.
      #
      # It is also the boundary the controllers already enforce
      # (`Chat.org_threads.where(user_id:)` in AssistantChatsController#set_chat and its
      # siblings), and a policy that states a WIDER rule than the doors is a policy
      # nobody can reason about. Step 5 empties and drops the column; this line goes
      # with it, not before.
      scope.org_threads.where(user_id: user.id)
    end

    private

    def assistant_available?
      ChatPolicy.assistant_gate_open?(user, organisation)
    end
  end

  def index?
    assistant_usable?
  end

  def create?
    # Owner is not negotiable (T2 hardening after the second review of T1):
    # a record carrying a FOREIGN owner must not pass, otherwise a write path
    # that forgot to force the owner server-side would authorize a thread its
    # caller could never read. An ownerless stand-in stays fine -- the actor
    # sets the owner, and Actors::SaveChat is pinned on doing so.
    assistant_usable? && (!record.is_a?(Chat) || record.user_id.nil? || record.user_id == user.id)
  end

  def show?
    assistant_usable? && owner?
  end

  def update?
    assistant_usable? && owner?
  end

  def destroy?
    assistant_usable? && owner?
  end

  # ONE owner for the §13-2 pair, called by the Scope AND the predicates (the
  # second review measured the two former hand copies drifting independently
  # under mutation). Operator flag + use_assistant permission PLUS an explicit
  # active-membership check: role_in_organisation -- the lookup behind
  # has_permission_in_organisation? -- does not ask membership.active. A gate
  # that must hold on its own cannot borrow it from upstream.
  def self.assistant_gate_open?(user, organisation)
    return false unless organisation

    organisation.assistant_enabled? &&
      user.active_member_of_organisation?(organisation) &&
      user.has_permission_in_organisation?(organisation, 'assistant', 'use_assistant')
  end

  private

  # NO admin bypass on purpose (see class comment). Asks Chat#personal? rather than
  # re-deriving `user_id?` here: the model declares that term as the ONE source.
  # nil owner is nobody, so an ownerless thread is denied rather than shared.
  def owner?
    record.is_a?(Chat) && record.personal? && record.user_id == user.id
  end

  def assistant_usable?
    ChatPolicy.assistant_gate_open?(user, organisation)
  end
end

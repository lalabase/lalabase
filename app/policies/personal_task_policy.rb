# frozen_string_literal: true

# Policy for PersonalTask — a member's private "Notizblock" to-dos.
#
# Strictly owner-only: there is deliberately NO account_admin bypass. An org
# admin must never see or touch another member's private to-dos — this is
# stronger than ordinary tenant scoping (user-private INSIDE the org). The Scope
# enforces the per-user wall for reads; the owner? action gate enforces it for
# writes (forged ids). acts_as_tenant adds the cross-tenant wall at the DB level.
class PersonalTaskPolicy < ApplicationPolicy
  # The drawer always shows the member their OWN list; the Scope guarantees they
  # only ever see their own rows.
  def index?
    true
  end

  # Creating a to-do for oneself. The controller forces user = current_user
  # (never from params), so a member can only ever create their own.
  def create?
    true
  end

  def show?
    owner?
  end

  def update?
    owner?
  end

  def destroy?
    owner?
  end

  class Scope < Scope
    def resolve
      scope.where(user: user)
    end
  end

  private

  # Owner-only — NO admin bypass on purpose (see class comment).
  def owner?
    record.user_id == user.id
  end
end

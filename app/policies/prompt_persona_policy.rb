# frozen_string_literal: true

# Authorization for the chat persona pool (Plan §13, v2 §3).
#
# Two distinct callers, two distinct concerns:
#   * The Scope (read) backs the chat picker — every member may SEE their org's
#     personas plus the global defaults, never another org's.
#   * The CRUD gates below govern the IN-APP per-org management controller
#     (Organisations::PromptPersonasController): only account-admins, only their
#     own org's rows. The operator backend (Admin::PromptPersonasController) is a
#     separate auth realm gated by the Beuser login (Admin::Authentication) and
#     does NOT go through Pundit — so it is intentionally absent from these gates.
class PromptPersonaPolicy < ApplicationPolicy
  # Managing personas is account-admin work. (The chat picker never calls
  # authorize — it reads through Scope — so tightening this from v1's
  # organisation.present? placeholder to account_admin? does not affect picking.)
  def index?
    account_admin?
  end

  # create/new authorize a freshly built instance; the controller forces
  # organisation_id to the current org (and system: false), so an admin can only
  # ever create for their own org — no record-level org check is needed here.
  def create?
    account_admin?
  end

  def new?
    create?
  end

  # Mutating an existing persona requires it to belong to the current org. Global
  # rows (organisation_id NULL) belong to the operator; another org's rows are off
  # limits — both fall through to false via org_owned?.
  def update?
    account_admin? && org_owned?
  end

  def edit?
    update?
  end

  # Ownership rule as in update?, plus a belt-and-suspenders system guard: per-org
  # personas are always system:false (the controller enforces it), but should a
  # system row ever reach here it must not be destroyable in-app (mirrors the
  # model's prevent_system_destroy).
  def destroy?
    account_admin? && org_owned? && !record.system?
  end

  class Scope < Scope
    def resolve
      return scope.none unless organisation

      scope.available_for(organisation)
    end
  end

  private

  # True only when the record is owned by the current tenant org. Guards against
  # editing or deleting global personas (organisation_id NULL) or another org's
  # personas through the in-app controller.
  def org_owned?
    record.organisation_id.present? && record.organisation_id == organisation&.id
  end
end

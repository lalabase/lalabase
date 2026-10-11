# frozen_string_literal: true

# Org-wide access matrix: a read-only grid of which member has which effective access to
# which project. Admin-only (AccessMatrixPolicy). See doc/zugriffs_matrix_plan.md.
class Organisations::AccessMatrixController < Organisations::BaseController
  def index
    authorize :access_matrix, :index?

    # policy_scope satisfies BaseController's enforced verify_policy_scoped on :index AND
    # supplies the row scope to the service (defence in depth on top of the admin gate).
    member_scope = policy_scope(Membership)
    @matrix = AccessCheck::OrgAccessMatrix.new(
      organisation: current_organisation,
      current_user: current_user,
      member_scope: member_scope
    )
  end
end

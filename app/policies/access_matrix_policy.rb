# frozen_string_literal: true

# Gate for the org-wide access matrix (Organisations::AccessMatrixController#index).
#
# The matrix is read-only, but it exposes every project's existence and full team
# composition at a glance — so v1 restricts it to account admins only. `manage_users` is
# deliberately NOT sufficient: it implies no project visibility, so allowing it would leak
# project existence and membership. (A non-admin partial view — scoped to the viewer's own
# projects — is a v1.1 backlog item; see doc/zugriffs_matrix_plan.md §9.)
#
# Headless policy: invoked as `authorize :access_matrix, :index?`.
class AccessMatrixPolicy < ApplicationPolicy
  def index?
    account_admin?
  end
end

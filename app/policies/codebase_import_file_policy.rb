# frozen_string_literal: true

class CodebaseImportFilePolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      # Only admins can see import files, and only while the operator switch is on.
      if organisation&.data_import_enabled? && user.account_admin_in?(organisation)
        scope.all
      else
        scope.none
      end
    end
  end

  def index?
    import_permitted?
  end

  def show?
    import_permitted?
  end

  def create?
    import_permitted?
  end

  def new?
    create?
  end

  def update?
    import_permitted?
  end

  def destroy?
    import_permitted?
  end

  # Additional actions
  def preview_import?
    import_permitted?
  end

  def execute_import?
    import_permitted?
  end

  def select_project?
    import_permitted?
  end

  def preview_tickets?
    import_permitted?
  end

  def execute_tickets_import?
    import_permitted?
  end

  def preview_time_sessions?
    import_permitted?
  end

  def execute_time_sessions_import?
    import_permitted?
  end

  def rollback?
    import_permitted?
  end

  def execute_rollback?
    import_permitted?
  end

  def assign_uploads?
    import_permitted?
  end

  def execute_upload_assignment?
    import_permitted?
  end

  private

  # The SINGLE gate every action above runs through. Two conditions, deliberately
  # in the policy rather than in the view or a before_action: the importer reads
  # one vendor's XML export only, so it stays dark for an organisation until an
  # operator flips `data_import_enabled` in the admin area. Hiding the tab alone
  # would still leave every POST (execute_import, execute_rollback, ...) reachable.
  # A new action inherits the gate by calling this instead of account_admin?.
  def import_permitted?
    return false unless organisation&.data_import_enabled?

    account_admin?
  end
end

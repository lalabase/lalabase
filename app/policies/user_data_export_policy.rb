# frozen_string_literal: true

# Owner-only. show/create run headless (class as record): the page and the
# request always operate on current_user's own exports — a data-subject right,
# open to every authenticated user, NEVER org-role-gated (Art. 15/20).
class UserDataExportPolicy < ApplicationPolicy
  def show?
    true
  end

  def create?
    true
  end

  def download?
    owner?
  end

  private

  def owner?
    record.is_a?(UserDataExport) ? record.user_id == user.id : true
  end
end

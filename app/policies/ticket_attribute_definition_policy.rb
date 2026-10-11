# frozen_string_literal: true

# Policy for ticket attribute definitions (custom fields)
# Only organisation admins have access
# The record is the Project, since attributes are project-scoped
class TicketAttributeDefinitionPolicy < ApplicationPolicy
  def manage?
    account_admin?
  end
end

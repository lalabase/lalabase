# frozen_string_literal: true

class AiSettingsPolicy < ApplicationPolicy
  # AI Settings Policy - only accessible to account admins
  #
  # This policy controls access to AI provider settings
  # and API key management. Only users with the account_admin role have
  # full access to these sensitive settings.

  def show?
    account_admin?
  end

  def update?
    account_admin?
  end

  def test_connection?
    account_admin?
  end

  # GDPR org-level AI opt-in (audit 2026-07-03): only org admins may switch
  # AI processing on/off for the whole organisation.
  def activate?
    account_admin?
  end

  def deactivate?
    account_admin?
  end

  # Special method for AI provider management
  def manage_providers?
    account_admin?
  end

  # Special method for API key management
  def manage_api_keys?
    account_admin?
  end

  # Special method for viewing usage statistics
  def view_usage_stats?
    account_admin?
  end

  class Scope < Scope
    def resolve
      # AI Settings are organisation-specific and only visible to admins
      if user.account_admin_in?(organisation)
        [organisation] # Return the current organisation
      else
        Organisation.none # No access for non-admins
      end
    end
  end
end

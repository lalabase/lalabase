# frozen_string_literal: true

# Policy for TimeSession statistics / the "Übersicht Abrechnungen" (Billing overview) tab.
# The record is the Organisation (not a model), since authorize is called with current_organisation.
# Aligned with TimeSessionGroupPolicy#index?: Admin or Finance/Buchhaltung.
class TimeSessionStatisticsPolicy < ApplicationPolicy
  def index?
    return false unless record

    user.account_admin_in?(record) || has_finance_role?(record)
  end

  private

  def has_finance_role?(organisation)
    user.memberships
        .joins(:role)
        .where(organisation: organisation, roles: { title: %w[Finance Buchhaltung finance buchhaltung] })
        .exists?
  end
end

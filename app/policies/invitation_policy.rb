# frozen_string_literal: true

class InvitationPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      return ActsAsTenant.without_tenant { Invitation.none } unless @organisation

      if user.account_admin_in?(@organisation)
        scope.where(organisation: @organisation)
      else
        scope.none
      end
    end
  end

  def index?
    true
  end

  def show?
    user_is_admin_in_organisation?
  end

  def new?
    create?
  end

  def create?
    user_is_admin_in_organisation?
  end

  def destroy?
    user_is_admin_in_organisation?
  end

  def copy_link?
    user_is_admin_in_organisation? && !record.accepted?
  end

  def resend?
    copy_link?
  end

  private

  def user_is_admin_in_organisation?
    # For new records use the organisation from the context
    org = record.organisation || @organisation
    return false unless org

    !!user.account_admin_in?(org)
  end
end

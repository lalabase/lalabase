# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record, :organisation

  def initialize(user, record)
    raise Pundit::NotAuthorizedError, 'must be logged in' unless user

    @user = user
    @record = record
    @organisation = ActsAsTenant.current_tenant
  end

  def index?
    false
  end

  def show?
    false
  end

  def create?
    false
  end

  def new?
    create?
  end

  def update?
    false
  end

  def edit?
    update?
  end

  def destroy?
    false
  end

  class Scope
    def initialize(user, scope)
      raise Pundit::NotAuthorizedError, 'must be logged in' unless user

      @user = user
      @scope = scope
      @organisation = ActsAsTenant.current_tenant
    end

    def resolve
      raise NotImplementedError, "You must define #resolve in #{self.class}"
    end

    private

    attr_reader :user, :scope, :organisation
  end

  protected

  # Check whether the user is an account admin
  def account_admin?
    return false unless organisation

    !!user.account_admin_in?(organisation)
  end

  # Check whether the user has a specific permission
  def has_permission?(category, action)
    return false unless organisation

    !!user.has_permission_in_organisation?(organisation, category, action)
  end
end

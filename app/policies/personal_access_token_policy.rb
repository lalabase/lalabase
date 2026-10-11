# frozen_string_literal: true

# Personal Access Tokens belong to a single user; only the owner can manage them.
class PersonalAccessTokenPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.where(user_id: user.id)
    end
  end

  def index?
    true
  end

  def new?
    create?
  end

  def create?
    user.present?
  end

  def show?
    owns_record?
  end

  def edit?
    update?
  end

  def update?
    owns_record?
  end

  def destroy?
    owns_record?
  end

  private

  def owns_record?
    record.user_id == user.id
  end
end

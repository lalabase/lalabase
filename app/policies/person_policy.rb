# frozen_string_literal: true

# The people directory of an organisation (Person). A right of its own
# (Permission::CATEGORIES[:people]): account admins have it without a row,
# every other role only when an admin grants it. manage_people (create, edit,
# delete, link) implies view_people. Grantable to billable: false roles, so a
# customer role can keep the list.
#
# Every predicate asks for an ACTIVE membership itself:
# User#has_permission_in_organisation? reads the role and does not look at
# membership.active (same reason as ChatPolicy.assistant_gate_open?).
class PersonPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    # The rows of this organisation, minus the rows linked to a member the
    # viewer may not see on the members page (MembershipPolicy::Scope). That
    # holds for a deactivated member too: deactivating can be undone, and until
    # then the row stays as hidden as the member was (review of S1, 28.10.2026).
    # A row whose member was removed lost its account (PersonLinkRelease) and is
    # a contact of the organisation. Nothing without the right.
    def resolve
      return scope.none unless organisation && PersonPolicy.view_allowed?(user, organisation)

      people = scope.where(organisation: organisation)
      return people if user.account_admin_in?(organisation)

      member_ids = Membership.where(organisation: organisation).select(:user_id)
      visible_member_ids = MembershipPolicy::Scope.new(user, Membership).resolve.select(:user_id)
      people.where(user_id: nil)
            .or(people.where.not(user_id: member_ids))
            .or(people.where(user_id: visible_member_ids))
    end
  end

  def self.view_allowed?(user, organisation)
    return false unless user.active_member_of_organisation?(organisation)

    user.account_admin_in?(organisation) ||
      Permission.granting_actions('people', 'view_people').any? do |action|
        user.has_permission_in_organisation?(organisation, 'people', action)
      end
  end

  def self.manage_allowed?(user, organisation)
    return false unless user.active_member_of_organisation?(organisation)

    user.account_admin_in?(organisation) ||
      user.has_permission_in_organisation?(organisation, 'people', 'manage_people')
  end

  def index?
    can_view?
  end

  def show?
    can_view? && same_organisation? && visible_record?
  end

  def create?
    can_manage?
  end

  def new?
    create?
  end

  def update?
    can_manage? && same_organisation? && visible_record?
  end

  def edit?
    update?
  end

  def destroy?
    update?
  end

  private

  def can_view?
    return false unless organisation

    self.class.view_allowed?(user, organisation)
  end

  def can_manage?
    return false unless organisation

    self.class.manage_allowed?(user, organisation)
  end

  def same_organisation?
    record.is_a?(Person) && record.organisation_id == organisation.id
  end

  # The record must be one the scope would list: a row linked to a member the
  # viewer cannot see is not readable by id either.
  def visible_record?
    Scope.new(user, Person).resolve.exists?(id: record.id)
  end
end

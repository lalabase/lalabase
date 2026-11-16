# frozen_string_literal: true

# Fixtures of the people list above the organisations (GET /people), shared by its
# service, request and browser specs: memberships with or without the people right,
# people and meetings, each created under the tenant of its organisation.
module AllPeopleHelpers
  # A membership with a role of its own: an account admin (sees every member and holds
  # the people right), or a role with the named people rights (none: no people right).
  def join_organisation(user, organisation, admin: false, rights: [], active: true)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, **(admin ? { title: Role::ACCOUNT_ADMIN_TITLE } : {}))
      rights.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
      create(:membership, user: user, organisation: organisation, role: role, active: active)
    end
  end

  # The membership keeps its place and loses the people right: a role without any.
  def take_people_right(user, organisation)
    ActsAsTenant.with_tenant(organisation) do
      Membership.find_by!(user: user, organisation: organisation).update!(role: create(:role, organisation: organisation))
    end
  end

  def person_in(organisation, **attributes)
    ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation, **attributes) }
  end

  # A meeting in a project of its own, with one participant: a last contact.
  def meeting_in(organisation, at:, person: nil, user: nil)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      meeting = create(:meeting, organisation: organisation, project: project, occurred_at: at)
      create(:meeting_participant, meeting: meeting, person: person, user: user, display_name: 'Gast')
    end
  end
end

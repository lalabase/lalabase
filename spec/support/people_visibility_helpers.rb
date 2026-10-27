# frozen_string_literal: true

# People a writer with view_people (and no wider rights) does not see in the
# people directory. The rule lives in MembershipPolicy::Scope: a member sees the
# colleagues of the projects they share, and these members' only project is a
# fresh one. PersonPolicy::Scope hides such a member's person row too.
#
# One place for the setup, so a change to the visibility rule is made once: a
# forgotten copy would leave a negative assertion green without testing anything.
# Include it where needed (`include PeopleVisibilityHelpers`).
module PeopleVisibilityHelpers
  def member_out_of_sight(organisation:, first_name: 'Hanna', last_name: 'Beispiel')
    user = create(:user, first_name: first_name, last_name: last_name)
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: create(:project, organisation: organisation),
                                tickets_access: :read_only)
    User.find(user.id)
  end

  # The person row of such a member, under the given name.
  def row_out_of_sight(organisation:, name:)
    create(:person, organisation: organisation, name: name, user: member_out_of_sight(organisation: organisation))
  end
end

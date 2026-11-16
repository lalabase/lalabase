# frozen_string_literal: true

# Memberships with a people right in a given organisation, for the specs of
# taking a contact over into another organisation (Actors::TakeOverPerson and
# its controller). Every record is created under its own tenant.
module PeopleTakeoverHelpers
  def takeover_role(organisation, *actions, title: nil)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, **{ title: title }.compact)
      actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
      role
    end
  end

  def takeover_join(user, organisation, *actions, active: true, title: nil)
    ActsAsTenant.with_tenant(organisation) do
      role = takeover_role(organisation, *actions, title: title)
      create(:membership, user: user, organisation: organisation, role: role, active: active)
    end
    user
  end

  def takeover_person(organisation, **attributes)
    ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation, **attributes) }
  end

  # Paused for Prosopite: a spec compares the counts of both tenants before
  # and after, the same query twice on purpose.
  def takeover_count(organisation)
    Prosopite.pause { ActsAsTenant.with_tenant(organisation) { Person.where(organisation: organisation).count } }
  end
end

RSpec.configure do |config|
  config.include PeopleTakeoverHelpers, :people_takeover
end

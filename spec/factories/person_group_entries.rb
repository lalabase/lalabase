# frozen_string_literal: true

# An entry names a row (person_id) or a member's account (user_id): pass one of them and
# the organisation. The owner is the group's.
FactoryBot.define do
  factory :person_group_entry do
    person_group
    owner { person_group.owner }
    organisation
  end
end

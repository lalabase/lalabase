# frozen_string_literal: true

# == Schema Information
#
# Table name: memberships
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(TRUE), not null
#  role            :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  role_id         :uuid
#  user_id         :uuid             not null
#
# Indexes
#
#  index_memberships_on_organisation_id              (organisation_id)
#  index_memberships_on_role_id                      (role_id)
#  index_memberships_on_user_id                      (user_id)
#  index_memberships_on_user_id_and_organisation_id  (user_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (role_id => roles.id)
#
FactoryBot.define do
  factory :membership do
    association :user
    association :organisation
    association :role
    active { true }
  end
end

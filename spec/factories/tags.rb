# frozen_string_literal: true

# == Schema Information
#
# Table name: tags
#
#  id              :uuid             not null, primary key
#  name            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  index_tags_on_name_and_organisation_id  (name,organisation_id) UNIQUE
#  index_tags_on_organisation_id           (organisation_id)
#  index_tags_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :tag do
    sequence(:name) { |n| "tag-#{n}" }
    association :organisation
  end
end

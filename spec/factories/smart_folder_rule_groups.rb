# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folder_rule_groups
#
#  id              :uuid             not null, primary key
#  name            :string
#  position        :integer          default(1), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  smart_folder_id :uuid             not null
#
# Indexes
#
#  index_smart_folder_rule_groups_on_smart_folder_id               (smart_folder_id)
#  index_smart_folder_rule_groups_on_smart_folder_id_and_position  (smart_folder_id,position)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_id => smart_folders.id)
#
FactoryBot.define do
  factory :smart_folder_rule_group do
    association :smart_folder
    name { Faker::Lorem.words(number: 2).join(' ') }
    position { 1 }
  end
end

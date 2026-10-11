# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folder_rules
#
#  id                         :uuid             not null, primary key
#  config                     :jsonb
#  display_value              :text
#  field                      :string           not null
#  operator                   :string           not null
#  position                   :integer          default(1), not null
#  value                      :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  smart_folder_rule_group_id :uuid             not null
#
# Indexes
#
#  idx_on_smart_folder_rule_group_id_position_5c8bc7ff32   (smart_folder_rule_group_id,position)
#  index_smart_folder_rules_on_config                      (config) USING gin
#  index_smart_folder_rules_on_field_and_operator          (field,operator)
#  index_smart_folder_rules_on_smart_folder_rule_group_id  (smart_folder_rule_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_rule_group_id => smart_folder_rule_groups.id)
#
FactoryBot.define do
  factory :smart_folder_rule do
    association :smart_folder_rule_group
    field { 'title' }
    operator { 'contains' }
    value { Faker::Lorem.word }
    position { 1 }
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folder_shares
#
#  id              :uuid             not null, primary key
#  can_edit        :boolean          default(FALSE)
#  can_share       :boolean          default(FALSE)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  smart_folder_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_smart_folder_shares_on_smart_folder_id              (smart_folder_id)
#  index_smart_folder_shares_on_smart_folder_id_and_user_id  (smart_folder_id,user_id) UNIQUE
#  index_smart_folder_shares_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_id => smart_folders.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :smart_folder_share do
    association :smart_folder
    association :user
    can_edit { false }
    can_share { false }
  end
end

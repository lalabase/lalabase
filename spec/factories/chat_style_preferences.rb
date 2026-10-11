# frozen_string_literal: true

# == Schema Information
#
# Table name: chat_style_preferences
#
#  id              :uuid             not null, primary key
#  length          :integer          default(2), not null
#  technicality    :integer          default(2), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_chat_style_preferences_on_organisation_id_and_user_id  (organisation_id,user_id) UNIQUE
#  index_chat_style_preferences_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
FactoryBot.define do
  factory :chat_style_preference do
    association :organisation
    association :user
    technicality { 2 }
    length { 2 }
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: chatposts
#
#  id               :uuid             not null, primary key
#  content          :text
#  model_used       :string
#  role             :enum             default("user"), not null
#  source_citations :jsonb            not null
#  source_coverage  :jsonb
#  token_usage      :jsonb            not null
#  tool_calls       :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  chat_id          :uuid             not null
#  organisation_id  :uuid             not null
#  user_id          :uuid
#
# Indexes
#
#  index_chatposts_on_chat_id          (chat_id)
#  index_chatposts_on_organisation_id  (organisation_id)
#
FactoryBot.define do
  factory :chatpost do
    chat
    user
    organisation { chat.organisation }
    role { 'user' }
    content { "Test message content #{rand(100)}" }
  end
end

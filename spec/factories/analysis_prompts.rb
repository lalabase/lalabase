# frozen_string_literal: true

# == Schema Information
#
# Table name: analysis_prompts
#
#  id              :uuid             not null, primary key
#  prompt_text     :text             not null
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  creator_id      :uuid
#  organisation_id :uuid             not null
#
FactoryBot.define do
  factory :analysis_prompt do
    sequence(:title) { |n| "Analyse-Vorlage #{n}" }
    prompt_text { 'Fasse die getroffenen Entscheidungen und offenen Punkte zusammen.' }
    association :organisation
    association :creator, factory: :user
  end
end

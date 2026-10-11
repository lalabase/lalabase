# frozen_string_literal: true

# == Schema Information
#
# Table name: fragments
#
#  id                 :uuid             not null, primary key
#  fragmentable_type  :string           not null
#  plain_text_content :text
#  version_token      :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  fragmentable_id    :uuid             not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  index_fragments_on_fragmentable     (fragmentable_type,fragmentable_id)
#  index_fragments_on_organisation_id  (organisation_id)
#  index_fragments_on_version_token    (version_token)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :fragment do
    plain_text_content { 'This is sample content for the fragment' }
    version_token { SecureRandom.hex(8) }
    association :organisation

    # Polymorphic association - can be associated with different models
    trait :for_ticket do
      association :fragmentable, factory: :ticket
    end

    trait :for_note do
      association :fragmentable, factory: :note
    end

    trait :for_post do
      association :fragmentable, factory: :post
    end
  end
end

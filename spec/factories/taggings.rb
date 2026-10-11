# frozen_string_literal: true

# == Schema Information
#
# Table name: taggings
#
#  id            :uuid             not null, primary key
#  taggable_type :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  tag_id        :uuid             not null
#  taggable_id   :uuid             not null
#  user_id       :uuid
#
# Indexes
#
#  index_taggings_on_tag_and_type      (tag_id,taggable_type)
#  index_taggings_on_tag_id            (tag_id)
#  index_taggings_on_taggable          (taggable_type,taggable_id)
#  index_taggings_on_taggable_and_tag  (taggable_type,taggable_id,tag_id)
#  index_taggings_on_user_id           (user_id)
#  index_taggings_uniqueness           (tag_id,taggable_type,taggable_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (tag_id => tags.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :tagging do
    association :tag
    association :taggable, factory: :note
  end
end

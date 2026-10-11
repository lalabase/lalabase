# frozen_string_literal: true

# spec/factories/posts.rb
# == Schema Information
#
# Table name: posts
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  is_private               :boolean          default(FALSE), not null
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  organisation_id          :uuid             not null
#  ticket_id                :uuid             not null
#  user_id                  :uuid
#  visible_to_user_id       :uuid
#
# Indexes
#
#  index_posts_on_organisation_id         (organisation_id)
#  index_posts_on_privacy                 (is_private,visible_to_user_id)
#  index_posts_on_ticket_and_privacy      (ticket_id,is_private)
#  index_posts_on_ticket_created          (ticket_id,created_at)
#  index_posts_on_ticket_privacy_created  (ticket_id,is_private,created_at)
#  index_posts_on_user_created            (user_id,created_at)
#  index_posts_on_user_id                 (user_id)
#  index_posts_on_visible_to_user_id      (visible_to_user_id)
#
# Foreign Keys
#
#  fk_rails_...  (visible_to_user_id => users.id)
#
FactoryBot.define do
  factory :post do
    association :ticket
    association :user
    association :organisation
    content { 'Post Inhalt' }
    create_embeddings { true }
  end
end

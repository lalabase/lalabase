# frozen_string_literal: true

# == Schema Information
#
# Table name: post_reactions
#
#  id              :uuid             not null, primary key
#  emoji           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  post_id         :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_post_reactions_on_organisation_id  (organisation_id)
#  index_post_reactions_on_post_id          (post_id)
#  index_post_reactions_on_post_user_emoji  (post_id,user_id,emoji) UNIQUE
#  index_post_reactions_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (post_id => posts.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class PostReaction < ApplicationRecord
  EMOJIS = %w[👍 ✅ 👀 ❤️ 🎉].freeze

  acts_as_tenant(:organisation)

  belongs_to :post
  belongs_to :user

  validates :emoji, inclusion: { in: EMOJIS }
  validates :emoji, uniqueness: { scope: %i[post_id user_id] }
  validate :same_organisation_as_post

  private

  def same_organisation_as_post
    return if post.nil? || organisation_id == post.organisation_id

    errors.add(:organisation, :invalid)
  end
end

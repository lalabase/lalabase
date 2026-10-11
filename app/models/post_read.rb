# frozen_string_literal: true

# == Schema Information
#
# Table name: post_reads
#
#  id              :uuid             not null, primary key
#  read_at         :datetime         not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  post_id         :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_post_reads_on_organisation_id  (organisation_id)
#  index_post_reads_on_post_id          (post_id)
#  index_post_reads_on_post_user        (post_id,user_id) UNIQUE
#  index_post_reads_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (post_id => posts.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class PostRead < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :post
  belongs_to :user

  validates :read_at, presence: true
  validates :user_id, uniqueness: { scope: :post_id }
  validate :same_organisation_as_post

  # Both receipt creation and fanout lock the existing post before touching a
  # notification. Unlike a newly inserted notification, this row is visible to
  # both connections. The lock lasts until the outer outbox transaction commits.
  def self.synchronize(post_id:)
    transaction do
      Post.where(id: post_id).lock('FOR NO KEY UPDATE').load
      yield
    end
  end

  def self.all_existing_posts_read?(post_ids:, user:, organisation:)
    receipts = where(user: user, organisation: organisation).select(:post_id)
    Post.where(id: post_ids, organisation: organisation).where.not(id: receipts).none?
  end

  private

  def same_organisation_as_post
    return if post.nil? || organisation_id == post.organisation_id

    errors.add(:organisation, :invalid)
  end
end

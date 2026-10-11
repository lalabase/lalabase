# frozen_string_literal: true

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

class Post < ApplicationRecord
  acts_as_tenant(:organisation)
  has_rich_text :content
  include RichTextEmbedGuard

  has_many :post_documents, dependent: :destroy
  accepts_nested_attributes_for :post_documents, allow_destroy: true

  has_many :post_reactions, dependent: :destroy
  has_many :post_reads, dependent: :destroy

  # Fragments for embeddings
  has_many :fragments, as: :fragmentable, dependent: :destroy

  # Import tracking
  has_many :imported_objects, as: :importable, dependent: :destroy

  # File attachments
  has_many_attached :attachments

  belongs_to :ticket, touch: true
  belongs_to :user
  belongs_to :visible_to_user, class_name: 'User', optional: true

  validates :content, presence: true

  # Scopes for privacy handling
  scope :public_posts, -> { where(is_private: false) }
  scope :private_posts, -> { where(is_private: true) }
  # THE rule for who may read a comment (PostPolicy#show? asks #readable_by?):
  # a public post everyone, a private one its addressee, its author and the
  # organisation's account admins. Anything shown to one reader goes through
  # this scope; anything shown to every reader of the ticket (an activity
  # excerpt, a summary, an AI answer) takes public_posts instead.
  # Guard: spec/architecture/post_visibility_guard_spec.rb.
  scope :readable_by, lambda { |user, organisation|
    next where(is_private: false) if user.nil?
    next where(organisation_id: organisation.id) if user.account_admin_in?(organisation)

    where(is_private: false).or(where(visible_to_user_id: user.id)).or(where(user_id: user.id))
  }

  # Callbacks - set visible_to_user before validation
  before_validation :set_visible_to_user_on_private
  validate :private_post_visibility_consistency

  before_save :extract_plain_text_content
  after_create_commit :auto_subscribe_author

  # Returns the total duration of all time sessions for this post's ticket
  def total_time_expenditure
    ticket.time_sessions.sum(:duration)
  end

  # Returns formatted time expenditure string
  def formatted_time_expenditure
    TimeSession.format_duration(total_time_expenditure)
  end

  # Privacy helper methods
  def private?
    is_private?
  end

  def public?
    !is_private?
  end

  # The predicate twin of .readable_by; the two must agree (post_readable_by_spec).
  def readable_by?(user)
    return true if public?
    return false if user.nil?
    return true if visible_to_user_id == user.id || user_id == user.id

    !!user.account_admin_in?(organisation)
  end

  private

  def extract_plain_text_content
    self.plain_text_version = content&.to_plain_text
    self.plain_text_word_count = count_words(content&.to_plain_text)
  end

  def count_words(text)
    text.split(/\s+/).reject(&:blank?).size
  end

  def set_visible_to_user_on_private
    if is_private? && visible_to_user.nil?
      self.visible_to_user = user
    elsif !is_private?
      self.visible_to_user = nil
    end
  end

  def private_post_visibility_consistency
    errors.add(:visible_to_user, :required_for_private) if is_private? && visible_to_user.nil?

    return unless !is_private? && visible_to_user.present?

    errors.add(:visible_to_user, :not_for_public)
  end

  def auto_subscribe_author
    return unless user && ticket

    NotificationSubscription.system_subscribe(user: user, item: ticket)
  end
end

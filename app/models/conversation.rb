# frozen_string_literal: true

# A conversation: messages between members of one organisation, for instance
# between an agency and its client. It holds the frame (who started it, an
# optional title, an optional project as a label); the messages are
# ConversationPost rows, the people ConversationParticipant rows.
#
# WHO READS A CONVERSATION is decided in one place, the scope .visible_to:
# somebody who has a participant row AND is an active member of the
# conversation's organisation. Nothing else opens it.
#
# * No right on a project. The project is a label somebody put on the
#   conversation. A member with every right on that project who does not take
#   part reads nothing.
# * No admin role. An account admin who does not take part reads nothing, not
#   a title and not a number. A conversation is correspondence between the
#   people in it.
# * No participant row, no reading. A participation ends by deleting its row.
# * No active membership, no reading. A deactivated or removed member keeps
#   the row and reads nothing until the membership is back.
#
# #visible_to? asks the scope and has no rule of its own. #visible_participants
# is the same rule from the other end (who of the participants reads now).
# ConversationPost.visible_to and ConversationPolicy are built on the scope.
# Guard: spec/architecture/conversation_visibility_guard_spec.rb refuses a read
# past the rule and the two terms above inside it.
#
# Nothing writes or reads these rows yet: no route, no screen, no notification.
class Conversation < ApplicationRecord
  MAX_TITLE_LENGTH = 255

  # The references to rows of an organisation, declared BEFORE acts_as_tenant:
  # acts_as_tenant 1.0.1 checks the tenant only of references declared before
  # the call, and only through the current tenant. same_organisation_references
  # holds them to the row's organisation on top, with or without a tenant set.
  TENANT_REFERENCES = %i[project].freeze

  belongs_to :project, optional: true

  acts_as_tenant(:organisation)

  belongs_to :creator, class_name: 'User'

  # Through the model, never by a raw delete: the database cascade removes the
  # rows of the posts and leaves their rich text behind.
  has_many :conversation_participants, dependent: :destroy
  has_many :conversation_posts, dependent: :destroy

  before_validation :normalize_title
  before_validation :start_the_clock, on: :create

  validates :title, length: { maximum: MAX_TITLE_LENGTH }
  validates :last_post_at, presence: true
  validate :same_organisation_references

  # THE read rule. Inside the tenant like every query of this model, so it
  # raises without one. Each conversation once, and it chains.
  scope :visible_to, lambda { |user|
    next none if user.nil?

    where(id: ConversationParticipant.where(user_id: user.id).select(:conversation_id))
      .where(organisation_id: Membership.active.where(user_id: user.id).select(:organisation_id))
  }

  def visible_to?(user)
    self.class.visible_to(user).exists?(id: id)
  end

  # The participants who read this conversation now, as users: whoever is in
  # here gets the conversation from .visible_to, and nobody else does.
  def visible_participants
    User.where(id: conversation_participants.select(:user_id))
        .where(id: Membership.active.where(organisation_id: organisation_id).select(:user_id))
  end

  private

  def normalize_title
    self.title = title.to_s.strip.presence
  end

  # The list orders by the last post. Until a post is written, that is the start.
  def start_the_clock
    self.last_post_at ||= Time.current
  end

  # The same check as in the glossary (TermCorrection), a copy on purpose: each
  # model names its own references. Read without the tenant's scope: a
  # reference to a row of another organisation must fail, not read as "no row"
  # (an optional reference would pass that way and keep the foreign id).
  def same_organisation_references
    TENANT_REFERENCES.each do |name|
      reflection = self.class.reflect_on_association(name)
      id = public_send(reflection.foreign_key)
      next if id.blank? || !will_save_change_to_attribute?(reflection.foreign_key)

      owner = ActsAsTenant.without_tenant { reflection.klass.unscoped.where(id: id).pick(:organisation_id) }
      errors.add(name, :invalid) unless owner && owner == organisation_id
    end
  end
end

# frozen_string_literal: true

# One entry in a conversation: a message somebody wrote, or a system entry
# ("somebody was added").
#
# * A message has a text (the rich text `content`) and no system_event.
# * A system entry has a system_event and no text. It holds a key and ids
#   (subject_user, second_user, invitation), never a name and never a
#   sentence: the names are read when the entry is shown, so an erased account
#   reads as anonymous there too. The model holds only the shape of the key;
#   the list of keys comes with the change that writes the first one.
#
# The author is always a person (user). origin says through which door the
# post came; only `web` is written so far.
#
# ⚠️ For whoever writes the first one: the model holds the conversation and the
# invitation to the row's organisation. It does not check that the author, or
# the people a system entry is about (subject_user, second_user), belong to
# it: users carry no organisation. The writer takes the author from the
# signed-in participant and the others from the members it may pick from.
#
# On purpose this model has no embeddings (no fragments), no activity trail
# (not Trackable) and no file attachments: a conversation is not searched, not
# read by the assistant and not listed in a feed.
#
# Who reads a post is the rule of its conversation: .visible_to joins the
# conversation and merges Conversation.visible_to.
class ConversationPost < ApplicationRecord
  KINDS = %w[message system].freeze
  ORIGINS = %w[web token assistant].freeze
  # A key, never a sentence: lower case, digits and underscores.
  SYSTEM_EVENT_FORMAT = /\A[a-z0-9_]{1,64}\z/

  # Declared BEFORE acts_as_tenant, and held to the row's organisation by
  # same_organisation_references (see Conversation).
  TENANT_REFERENCES = %i[conversation invitation].freeze

  belongs_to :conversation
  belongs_to :invitation, optional: true

  acts_as_tenant(:organisation)

  has_rich_text :content
  include RichTextEmbedGuard
  include RichTextBody

  # A system entry has no text. The mirror would ask for `content` and so
  # build an empty rich text record for it.
  skip_callback :save, :before, :extract_plain_text_content, if: :system?
  before_save :clear_system_entry_mirror, if: :system?

  belongs_to :user
  belongs_to :subject_user, class_name: 'User', optional: true
  belongs_to :second_user, class_name: 'User', optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :origin, inclusion: { in: ORIGINS }
  validates :content, presence: true, if: :message?
  validates :system_event, presence: true, format: { with: SYSTEM_EVENT_FORMAT, allow_blank: true }, if: :system?
  validate :message_has_no_system_event
  validate :system_entry_has_no_text
  validate :same_organisation_references

  scope :visible_to, ->(user) { joins(:conversation).merge(Conversation.visible_to(user)) }

  def message?
    kind == 'message'
  end

  def system?
    kind == 'system'
  end

  private

  def clear_system_entry_mirror
    self.plain_text_version = nil
    self.plain_text_word_count = nil
  end

  def message_has_no_system_event
    errors.add(:system_event, :not_for_a_message) if message? && !system_event.nil?
  end

  # Asks the association, not `content`: the reader would build the record.
  def system_entry_has_no_text
    errors.add(:content, :not_for_a_system_entry) if system? && rich_text_content&.body.present?
  end

  # The same check as in Conversation and the glossary, a copy on purpose.
  # Read without the tenant's scope: a conversation or an invitation of
  # another organisation must fail, not read as "no row".
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

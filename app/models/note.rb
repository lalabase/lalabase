# frozen_string_literal: true

# == Schema Information
#
# Table name: notes
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  description              :text
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  lock_version             :integer          default(0), not null
#  markdown_body            :text
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  creator_id               :uuid             not null
#  organisation_id          :uuid             not null
#  project_id               :uuid             not null
#
# Indexes
#
#  index_notes_on_creator_id       (creator_id)
#  index_notes_on_organisation_id  (organisation_id)
#  index_notes_on_project_id       (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#
class Note < ApplicationRecord
  # Trackable removed - we only want project activities

  acts_as_tenant(:organisation)
  has_rich_text :content
  include RichTextEmbedGuard
  include OneLineText

  belongs_to :project
  belongs_to :creator, class_name: 'User'

  # Fragments for embeddings
  has_many :fragments, as: :fragmentable, dependent: :delete_all

  # Wiki: version history + outgoing links.
  # Incoming links (backlinks = Reference.pointing_to(note)) are deliberately NOT
  # destroyed with the note → they survive as a tombstone (target_title_snapshot)
  # when this note is deleted.
  has_many :note_versions, dependent: :destroy
  has_many :outgoing_references, class_name: 'Reference', as: :source, dependent: :destroy

  # Tagging System
  include Taggable

  # Wiki: linkable from another note via an @-mention (ActionText::Attachable).
  include Wiki::Mentionable

  validates :title, presence: true
  validates :content, presence: true
  # Wiki content invariant (D2): round-trip-safe content only. As a validation so
  # save! raises RecordInvalid with a usable message (instead of an exception).
  validate :wiki_content_roundtrip_safe

  before_save :extract_plain_text_content
  # Wiki save lifecycle (D2): invariants live in the model so every write path runs
  # them (UI, console, import, later MCP) — not only the SaveNote actor.
  #
  # ORDER IS LOAD-BEARING: assign_wiki_markdown_body (before_save) must run BEFORE the
  # two after_save hooks — both gate on the markdown_body dirty trace it produces (see
  # #wiki_content_changed?). Reordering, or moving either after_save hook into
  # before_save, silently breaks the "version/reference only on real change" dedup.
  before_save :assign_wiki_markdown_body
  after_save :snapshot_note_version
  after_save :rebuild_wiki_references
  after_create_commit :track_note_created_in_project

  # The title as ONE line, cut to `max` (OneLineText): the assistant's reference
  # chip and system prompt name a note by it, each with its own bound. The twin
  # of Ticket#one_line_title, minus the number a note does not have.
  def one_line_title(max:)
    one_line(title, max:)
  end

  # Returns the total duration of all time sessions for the project
  def total_time_expenditure
    project.time_sessions.sum(:duration)
  end

  # Returns formatted time expenditure string
  def formatted_time_expenditure
    TimeSession.format_duration(total_time_expenditure)
  end

  private

  def extract_plain_text_content
    self.plain_text_version = content&.to_plain_text
    self.plain_text_word_count = count_words(content&.to_plain_text)
  end

  def count_words(text)
    text.split(/\s+/).reject(&:blank?).size
  end

  # Track note creation in project activities
  def track_note_created_in_project
    project.track_note_created(self) if project.respond_to?(:track_note_created)
  end

  # ── Wiki save lifecycle ─────────────────────────────────────────────────
  #   content(HTML) ─validate─▶ round-trip-safe? (GFM guard)
  #                 ─before_save─▶ derive markdown_body (same serializer as backfill)
  #                 ─after_save──▶ NoteVersion (new state; dedup via markdown_body dirty trace)

  def wiki_serializer
    @wiki_serializer ||= Wiki::MarkdownSerializer.new
  end

  def wiki_content_html
    content&.body&.to_html
  end

  # Only a content-changing save needs the GFM guard + markdown re-derivation; a title-only
  # update leaves the already-validated content untouched. content.changed? is a reliable
  # signal here (verified), and BOTH the guard and the derivation gate on it together: the
  # derivation also runs the serializer (which raises on block-in-cell), so skipping the
  # guard alone would turn a title-only save of (e.g. imported) bad content into a 500
  # instead of a clean no-op.
  def wiki_content_changing?
    new_record? || content&.changed?
  end

  def wiki_content_roundtrip_safe
    return unless wiki_content_changing?

    html = wiki_content_html
    return if html.blank?

    wiki_serializer.assert_roundtrip_safe!(html)
  rescue Wiki::MarkdownSerializer::BlockContentInTableCellError
    errors.add(:content, :block_content_in_table_cell)
  end

  def assign_wiki_markdown_body
    return unless wiki_content_changing?

    html = wiki_content_html
    self.markdown_body = html.blank? ? nil : wiki_serializer.to_markdown(html)
  end

  # Did the note's content actually change on this save? Both wiki after_save hooks
  # gate on this single predicate so a title-only save and bulk/fixture creates churn
  # neither the version history nor the reference index.
  #
  # WHY trace the DERIVED markdown_body column and not the content: ActionText rich text
  # has no reliable dirty trace, but the markdown_body column does — and (the serializer
  # being deterministic: same content ⟹ same markdown_body) it changes exactly when the
  # content does. So this also avoids an extra "did anything change?" dedup query.
  def wiki_content_changed?
    saved_change_to_markdown_body?
  end

  # The org is passed as an OBJECT (not reloaded) so the belongs_to validation does not
  # trigger an N+1 on bulk/fixture saves.
  def snapshot_note_version
    return unless wiki_content_changed?

    html = wiki_content_html
    return if html.blank?

    note_versions.create!(
      organisation: ActsAsTenant.current_tenant,
      **NoteVersion.snapshot_attributes(html: html, markdown: markdown_body, author: Current.user)
    )
  end

  # Rebuild the outgoing link index from the CANONICAL HTML (sgid attachments), not
  # from the derived markdown — a serializer bug must not corrupt the link graph.
  # delete+insert keeps it in sync. Self-mentions are skipped (a self-reference is invalid).
  def rebuild_wiki_references
    return unless wiki_content_changed?

    targets = Wiki::ReferenceExtractor.new.call(wiki_content_html)
    outgoing_references.delete_all
    targets.each do |target|
      next if target == self

      outgoing_references.create!(
        organisation: ActsAsTenant.current_tenant,
        target: target,
        # Truncate: the snapshot is a display label and must never fail the save.
        # A target title (PG varchar, unbounded) can exceed the column's 255 guard.
        target_title_snapshot: target.try(:title)&.truncate(255)
      )
    end
  end
end

# frozen_string_literal: true

# Version history + diff basis per note.
#
#   save     ──▶ new NoteVersion (NEW state)            [design D4]
#   backfill ──▶ v0 (original Trix HTML)
#   diff(v0, v1) shows exactly what the Lexxy re-serialization changed.
#
# No-op dedup (same content → no new version) is done by the Note after_save callback
# via the dirty trace of the markdown_body column — NOT this content_hash. content_hash
# is stored per version for integrity / as a diff anchor / future use.
# Invariant: current note == latest version.
# == Schema Information
#
# Table name: note_versions
#
#  id              :uuid             not null, primary key
#  content_hash    :string           not null
#  html_body       :text
#  markdown_body   :text
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  author_id       :uuid
#  note_id         :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_note_versions_on_note_id_and_created_at  (note_id,created_at)
#  index_note_versions_on_organisation_id         (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (author_id => users.id)
#  fk_rails_...  (note_id => notes.id)
#
class NoteVersion < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :note
  belongs_to :author, class_name: 'User', optional: true

  validates :content_hash, presence: true

  scope :chronological, -> { order(:created_at) }

  # Stable hash of the canonical HTML, stored per version (integrity / diff anchor).
  # The no-op dedup itself runs via the markdown_body dirty trace in Note, not via this.
  def self.digest_for(html)
    Digest::SHA256.hexdigest(html.to_s)
  end

  # The content columns that make up a version snapshot, derived from a note's
  # current state. One definition shared by the live save callback
  # (Note#snapshot_note_version) and the one-time backfill (Wiki::NoteBackfill), so
  # "what a version is" — which columns, how the integrity hash is derived — lives in
  # exactly one place. organisation/note are the caller's tenancy concern and stay out.
  def self.snapshot_attributes(html:, markdown:, author:)
    {
      html_body: html,
      markdown_body: markdown,
      content_hash: digest_for(html),
      author: author
    }
  end
end

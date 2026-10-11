# frozen_string_literal: true

require 'rails_helper'

# What:  NoteVersion — version history + diff basis per note.
# Type:  Model spec (DB), tenant-scoped.
# Why:   The version semantics (D4: new state per save, dedup via the markdown_body
#        dirty trace, tenant isolation) carry the migration safety net and the diffs.
#        We test the contracts at the decision points, not just lines.
# Contracts:
#   - content_hash is required.
#   - author is optional (system/backfill versions have no author).
#   - digest_for is stable + content-sensitive (the per-version integrity hash).
#   - chronological orders the history.
#   - versions of one org are invisible under another org (acts_as_tenant).
RSpec.describe NoteVersion, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation)       { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # Creating a note already adds a version via the Wiki after_save callback (new
  # state). For the pure model tests we start with an empty history to control the
  # version count exactly.
  let(:note) { create(:note, organisation: organisation).tap { |n| n.note_versions.delete_all } }

  describe 'validations' do
    it 'is invalid without a content_hash' do
      version = NoteVersion.new(note: note, content_hash: nil)
      expect(version).not_to be_valid
      expect(version.errors[:content_hash]).to be_present
    end

    it 'allows a blank author (backfill/system versions)' do
      version = NoteVersion.new(note: note, content_hash: 'abc', author: nil)
      version.valid?
      expect(version.errors[:author]).to be_empty
    end
  end

  describe '.digest_for' do
    # Intent: same content → same hash; different content → different hash.
    it 'is stable and content-sensitive' do
      a = described_class.digest_for('<p>same</p>')
      expect(described_class.digest_for('<p>same</p>')).to eq(a)
      expect(described_class.digest_for('<p>different</p>')).not_to eq(a)
    end
  end

  describe '.chronological' do
    it 'orders versions by creation time' do
      v0 = travel_to(2.minutes.ago) { create_version(note, 'v0') }
      v1 = travel_to(1.minute.ago)  { create_version(note, 'v1') }
      expect(note.note_versions.chronological).to eq([v0, v1])
    end
  end

  describe 'tenant isolation' do
    it 'does not show versions of one org under another' do
      create_version(note, 'secret')
      ActsAsTenant.with_tenant(other_organisation) do
        expect(NoteVersion.count).to eq(0)
      end
      expect(NoteVersion.count).to eq(1)
    end
  end

  describe 'DB-level constraints (defense in depth)' do
    # Mutation guard: someone drops `validates :content_hash, presence: true` as
    # "redundant" — the DB NOT NULL must still bite. organisation is set explicitly
    # because save(validate: false) skips acts_as_tenant's tenant assignment, so the
    # only NULL is content_hash and the error fails for the RIGHT reason.
    it 'raises NotNullViolation when the content_hash validation is bypassed' do
      version = NoteVersion.new(note: note, organisation: organisation, content_hash: nil)
      expect { version.save!(validate: false) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'cascade on parent destroy' do
    # Mutation guard: removing `has_many :note_versions, dependent: :destroy` from
    # Note turns this red (the FK then blocks the delete, or the version is orphaned).
    it 'is destroyed when its note is destroyed' do
      create_version(note, 'v')
      # reload: the version was inserted out-of-band (NoteVersion.create!), so the
      # note's cached association is stale; reload lets dependent: :destroy see it.
      expect { note.reload.destroy! }.to change(NoteVersion, :count).by(-1)
    end
  end

  describe '.snapshot_attributes' do
    # Mutation guard: this builder is shared by the live save callback and the backfill,
    # so a swap of html_body/markdown_body, a dropped key, or hashing the wrong field
    # would corrupt EVERY version written through it. The indirect callback/backfill
    # tests do not assert the markdown_body mapping — so we pin the full mapping here.
    it 'maps each field to its column, hashes the html, and carries the author through' do
      author = build_stubbed(:user)

      attrs = described_class.snapshot_attributes(html: '<p>h</p>', markdown: 'h', author: author)

      expect(attrs).to eq(
        html_body: '<p>h</p>',
        markdown_body: 'h',
        content_hash: described_class.digest_for('<p>h</p>'),
        author: author
      )
    end
  end

  def create_version(note, body)
    NoteVersion.create!(
      note: note,
      html_body: "<p>#{body}</p>",
      markdown_body: body,
      content_hash: described_class.digest_for("<p>#{body}</p>")
    )
  end
end

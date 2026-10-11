# frozen_string_literal: true

require 'rails_helper'

# What:  Wiki::NoteBackfill — the one-time migration that lifts pre-Wiki notes onto the
#        D2/D4 contract (markdown_body + a v0 baseline version).
# Type:  Service spec (DB), tenant-scoped.
# Why:   A data backfill runs once against real customer data — it must be exact AND
#        re-runnable. We test the hard contracts: it derives markdown, it creates exactly
#        one baseline version, it is idempotent, it does NOT churn updated_at/lock_version
#        (the whole reason it bypasses the callbacks), it skips blank notes, and it stays
#        inside the tenant.
RSpec.describe Wiki::NoteBackfill do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # A note as it existed BEFORE the Wiki migration: the create callbacks already filled
  # markdown_body and a version, so we strip both to reproduce the legacy row (column was
  # added NULL, no version history). update_column keeps updated_at controllable.
  def legacy_note(content: '<div>Hello <strong>world</strong></div>', org: organisation)
    note = create(:note, organisation: org, content: content)
    note.note_versions.delete_all
    note.update_column(:markdown_body, nil)
    note
  end

  describe 'derivation' do
    it 'fills markdown_body from the canonical content HTML' do
      note = legacy_note

      described_class.call

      expect(note.reload.markdown_body).to include('**world**')
    end

    it 'creates exactly one v0 version with a nil author and the content hash' do
      note = legacy_note

      expect { described_class.call }.to change { note.note_versions.count }.from(0).to(1)

      # reload: the backfill mutates via its own find_each instance, so the test's note
      # has a stale (loaded-empty) association cache that .sole would otherwise honor.
      version = note.reload.note_versions.sole
      expect(version.author).to be_nil
      expect(version.html_body).to eq(note.reload.content.body.to_html)
      expect(version.content_hash).to eq(NoteVersion.digest_for(note.content.body.to_html))
    end

    it 'reports what it did' do
      legacy_note
      result = described_class.call
      expect(result).to have_attributes(filled: 1, versioned: 1, skipped_blank: 0)
    end
  end

  describe 'idempotency' do
    # Mutation guard: dropping the `exists?` guard on the version step would create a
    # second v0 on the second run; dropping the markdown_body filter would re-fill it.
    it 'does not create a second version or re-fill markdown on a re-run' do
      note = legacy_note
      described_class.call

      expect { described_class.call }.not_to(change { note.note_versions.count })
      expect(described_class.call).to have_attributes(filled: 0, versioned: 0)
    end

    # Mutation guard for the `exists?` guard on the version step, exercised surgically:
    # an interrupted run can leave a note with a v0 but still no markdown_body (version is
    # written first, on purpose). A re-run must fill the markdown WITHOUT adding a 2nd v0.
    # Dropping the exists? guard turns this red (count goes 1 → 2).
    it 'fills markdown without a second version when a version already exists' do
      note = legacy_note
      note.note_versions.create!(
        organisation: organisation,
        **NoteVersion.snapshot_attributes(html: note.content.body.to_html, markdown: 'stale', author: nil)
      )

      expect { described_class.call }.not_to(change { note.reload.note_versions.count })
      expect(note.reload.markdown_body).to include('**world**')
    end

    # Mutation guard: replacing update_column with update!/save would fire the callbacks
    # and bump updated_at + lock_version — exactly what this backfill must NOT do.
    it 'leaves updated_at and lock_version untouched' do
      note = legacy_note
      frozen = 3.days.ago.change(usec: 0)
      note.update_columns(updated_at: frozen, lock_version: 0)

      described_class.call

      expect(note.reload.updated_at).to eq(frozen)
      expect(note.lock_version).to eq(0)
    end
  end

  describe 'already-migrated notes' do
    # Mutation guard: a note that already has markdown_body (created post-migration via the
    # callback) must be skipped entirely — widening the filter would re-version live notes.
    it 'does not touch a note that already has markdown_body and a version' do
      note = create(:note, organisation: organisation, content: '<div>fresh</div>')
      expect(note.markdown_body).to be_present
      expect(note.note_versions.count).to eq(1)

      expect { described_class.call }.not_to(change { note.note_versions.count })
    end
  end

  describe 'blank content' do
    # Intent: a note whose rich-text body renders blank gets no markdown and no version
    # (mirrors the callback's blank guard) and is counted as skipped, not as an error.
    # `validates :content, presence: true` prevents an empty note at create, so we
    # reproduce the edge/legacy row (content deleted post-create) by dropping the body.
    it 'skips a note whose content renders blank' do
      note = legacy_note
      ActionText::RichText.where(record: note).delete_all
      note.reload

      result = described_class.call

      expect(note.reload.markdown_body).to be_nil
      expect(note.note_versions).to be_empty
      expect(result).to have_attributes(filled: 0, versioned: 0, skipped_blank: 1)
    end
  end

  describe 'tenant scoping' do
    let(:other_organisation) { create(:organisation) }

    # Mutation guard: the per-tenant ActsAsTenant.with_tenant wrapping. Scoped to one org,
    # the other org's legacy notes stay untouched.
    it 'only backfills the given organisation when scoped' do
      mine = legacy_note
      theirs = ActsAsTenant.with_tenant(other_organisation) { legacy_note(org: other_organisation) }

      described_class.call(organisation: organisation)

      expect(mine.reload.markdown_body).to be_present
      ActsAsTenant.with_tenant(other_organisation) do
        expect(theirs.reload.markdown_body).to be_nil
        expect(theirs.note_versions).to be_empty
      end
    end

    it 'sweeps every organisation when unscoped' do
      mine = legacy_note
      theirs = ActsAsTenant.with_tenant(other_organisation) { legacy_note(org: other_organisation) }

      described_class.call

      expect(mine.reload.markdown_body).to be_present
      ActsAsTenant.with_tenant(other_organisation) do
        expect(theirs.reload.markdown_body).to be_present
        expect(theirs.note_versions.count).to eq(1)
      end
    end
  end
end

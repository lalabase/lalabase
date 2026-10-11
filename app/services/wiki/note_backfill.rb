# frozen_string_literal: true

module Wiki
  # One-time backfill that brings pre-Wiki notes up to the D2/D4 contract:
  #   - markdown_body derived from the canonical Trix HTML (same serializer as runtime)
  #   - a v0 NoteVersion as the baseline of the version history
  #
  # WHY a maintenance service and NOT the model callbacks: a backfill must not bump
  # updated_at, must not bump lock_version, and must not re-validate legacy content (a
  # never-launched Wiki rule cannot retroactively invalidate notes a user already saved).
  # So it writes markdown_body with update_column (callback-free) and inserts the version
  # directly — reusing the SAME primitives the callbacks use (Wiki::MarkdownSerializer +
  # NoteVersion.snapshot_attributes), so there is exactly one derivation, never two.
  #
  # Idempotent + crash-safe: only notes still missing markdown_body are selected, and the
  # version is created BEFORE markdown_body is persisted. So an interrupted run leaves the
  # note selectable again (markdown_body still nil), the version step is guarded by
  # exists?, and a re-run completes it without ever writing a second v0. Safe to re-run.
  #
  # Tenant-scoped: notes are acts_as_tenant, so the work runs inside
  # ActsAsTenant.with_tenant per organisation. Pass organisation: to scope to one tenant
  # (tests / targeted reruns); omit it to sweep every organisation.
  class NoteBackfill
    BATCH_SIZE = 500

    Result = Struct.new(:filled, :versioned, :skipped_blank, keyword_init: true) do
      def to_s
        "filled=#{filled} versioned=#{versioned} skipped_blank=#{skipped_blank}"
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # on_progress: optional callable, invoked once per processed note (for a CLI ticker).
    def initialize(organisation: nil, on_progress: nil)
      @organisation = organisation
      @on_progress = on_progress
      @serializer = Wiki::MarkdownSerializer.new
      @result = Result.new(filled: 0, versioned: 0, skipped_blank: 0)
    end

    def call
      organisations.each do |org|
        ActsAsTenant.with_tenant(org) { backfill_tenant(org) }
      end
      @result
    end

    private

    def organisations
      @organisation ? [@organisation] : Organisation.all
    end

    def backfill_tenant(org)
      # markdown_body IS NULL is the work filter; with_rich_text_content preloads the
      # ActionText body so reading each note's HTML does not become an N+1.
      Note.where(markdown_body: nil)
          .with_rich_text_content
          .find_each(batch_size: BATCH_SIZE) do |note|
        backfill_note(note, org)
        @on_progress&.call(@result)
      end
    end

    def backfill_note(note, org)
      html = note.content&.body&.to_html
      if html.blank?
        # No content → nothing to derive and nothing to version (mirrors the callback's
        # blank guard). markdown_body stays nil; harmless no-op on re-runs.
        @result.skipped_blank += 1
        return
      end

      markdown = @serializer.to_markdown(html)
      # Order matters (crash safety): version first, then markdown_body. An interrupted
      # run leaves the note still selectable (markdown_body nil) so a re-run finishes it.
      create_baseline_version(note, org, html, markdown)
      fill_markdown(note, markdown)
    end

    def create_baseline_version(note, org, html, markdown)
      return if note.note_versions.exists?

      note.note_versions.create!(
        organisation: org,
        # author nil: the backfill has no acting user; v0 is a system baseline.
        **NoteVersion.snapshot_attributes(html: html, markdown: markdown, author: nil)
      )
      @result.versioned += 1
    end

    def fill_markdown(note, markdown)
      # update_column: callback-free, no updated_at / lock_version churn. update_column
      # also refreshes the in-memory attribute, so the note object stays consistent.
      note.update_column(:markdown_body, markdown)
      @result.filled += 1
    end
  end
end

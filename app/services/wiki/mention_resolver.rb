# frozen_string_literal: true

module Wiki
  # Resolves the signed GlobalID (sgid) of an ActionText mention attachment to the
  # referenced record.
  #
  # Deliberately SEPARATE from MarkdownSerializer (pure transformation): identity
  # resolution is its own DB-/GlobalID-near concern. The separation keeps the
  # serializer testable without a DB (fake resolver) and lets brick 3b (reference
  # rebuild) reuse THE SAME resolution instead of duplicating it.
  #
  # Two entry points:
  #   record_for(sgid) → the record       (reference rebuild needs `target: record`)
  #   call(sgid)       → { type:, id:, title: }  (the serializer builds the link from this)
  #
  # Tolerates missing/invalid/unresolvable sgids (→ nil) so a deleted target does
  # not blow up the whole save. The exact wiring (sgid purpose, title source,
  # policy_scope check on the write path) is refined when the mention feature is built.
  class MentionResolver
    def record_for(sgid)
      return nil if sgid.blank?

      # ActionText (and Lexxy) sign mention attachment sgids with the "attachable" PURPOSE,
      # not the default GlobalID purpose. locate_signed with the default purpose silently
      # fails to resolve a real mention (verified), so we go through ActionText's own
      # attachable locator — the same path ActionText uses when rendering the attachment.
      ActionText::Attachable.from_attachable_sgid(sgid)
    rescue StandardError
      # Broad on purpose: sgids arrive from stored HTML, imports and (later) AI/MCP
      # writes — i.e. partly stale or externally controlled. A bad signature, an unknown
      # model class, a vanished record etc. must all degrade to "unresolvable" (nil) and
      # never raise into the caller, which would break a note save or a render.
      nil
    end

    def call(sgid)
      record = record_for(sgid)
      return nil unless record

      { type: record.model_name.element, id: record.id, title: title_for(record) }
    end

    private

    def title_for(record)
      record.respond_to?(:title) ? record.title : record.to_s
    end
  end
end

# frozen_string_literal: true

# One-off data sweep (spike plan Inline-Bilder, D9): removes the `url` and `href`
# attributes from every stored <action-text-attachment> node. Those attributes carried a
# signed_id without expiry, a permanent, login-free link to the file; since Paket 1
# RichTextEmbedGuard strips them on save, this sweep does the same for the rich texts
# written before. Writes with update_column on purpose: no validation, no NoteVersion,
# no embeds sync, only the attribute; a note's derived markdown_body is re-derived the
# same way so the version history does not show a spurious diff on the next edit.
# Idempotent: a node without the attributes is left alone and not counted.
#
# Entry point: RichTextEmbedUrlSweep.call(dry_run: true)
class RichTextEmbedUrlSweep
  Result = Struct.new(:scanned, :changed, :dry_run, keyword_init: true)

  def self.call(dry_run: true) = new(dry_run: dry_run).call

  def initialize(dry_run: true)
    @dry_run = dry_run
  end

  def call
    scanned = 0
    changed = 0

    ActsAsTenant.without_tenant do
      candidates.find_each do |rich_text|
        scanned += 1
        stripped = strip(rich_text.body.to_html)
        next if stripped.nil?

        changed += 1
        persist(rich_text, stripped) unless @dry_run
      end
    end

    Result.new(scanned: scanned, changed: changed, dry_run: @dry_run)
  end

  private

  def candidates
    ActionText::RichText.where('body LIKE ?', "%<#{ActionText::Attachment.tag_name}%")
  end

  # @return [String, nil] the html without the attributes, or nil when nothing changed
  def strip(html)
    fragment = ActionText::Fragment.wrap(html)
    touched = false
    fragment.find_all(ActionText::Attachment.tag_name).each do |node|
      RichTextEmbedGuard::STRIPPED_ATTACHMENT_ATTRIBUTES.each do |attr|
        next unless node.has_attribute?(attr)

        node.remove_attribute(attr)
        touched = true
      end
    end
    touched ? fragment.to_html : nil
  end

  def persist(rich_text, html)
    rich_text.update_column(:body, html)
    carrier = rich_text.record
    return unless carrier.is_a?(Note) && carrier.has_attribute?(:markdown_body)

    carrier.update_column(:markdown_body, Wiki::MarkdownSerializer.new.to_markdown(html))
  end
end

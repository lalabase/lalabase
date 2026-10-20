# frozen_string_literal: true

# One-off repair after a secret_key_base rotation: every
# <action-text-attachment sgid> stored before it was signed with the old key, so Rails
# renders each image and wiki mention as "☒". This re-signs those nodes with the current key.
#
# The old key is an argument of this one run, never configuration: a key is rotated because
# others may hold it, and a sgid forged with it must not gain a target. So a node is re-signed only when
#   1. the old key verifies it (an unverified sgid is never decoded: older ones are Marshal),
#   2. its record still exists, and
#   3. the record belongs to this text: a blob only when it is attached to THIS rich text
#      (its embeds), anything else (a mention) only within the carrier's organisation.
# Everything else is counted (unreadable) or listed with its ids (gone, refused); a gone
# blob was purged after the rotation and can only come back from the attachment backup.
#
# Writes with update_column like RichTextEmbedUrlSweep: no validation, no NoteVersion, no
# embeds sync; a note's derived markdown_body is re-derived so the next edit shows no
# spurious diff. Idempotent: a node that resolves is left alone.
#
# Entry point: RichTextSgidResign.call(old_secret_key_base:, dry_run: true)
class RichTextSgidResign
  Result = Struct.new(:scanned, :changed, :resigned, :unreadable, :gone, :refused, :dry_run, keyword_init: true)

  def self.call(old_secret_key_base:, dry_run: true) = new(old_secret_key_base: old_secret_key_base, dry_run: dry_run).call

  def initialize(old_secret_key_base:, dry_run: true)
    raise ArgumentError, 'old_secret_key_base is required' if old_secret_key_base.blank?

    # The same derivation GlobalID's railtie uses for SignedGlobalID.verifier.
    @old_verifier = GlobalID::Verifier.new(Rails.application.key_generator(old_secret_key_base).generate_key('signed_global_ids'))
    @dry_run = dry_run
  end

  def call
    @result = Result.new(scanned: 0, changed: 0, resigned: 0, unreadable: 0, gone: [], refused: [], dry_run: @dry_run)

    ActsAsTenant.without_tenant do
      candidates.find_each do |rich_text|
        @result.scanned += 1
        html = resign(rich_text)
        next if html.nil?

        @result.changed += 1
        persist(rich_text, html) unless @dry_run
      end
    end

    @result
  end

  private

  def candidates
    ActionText::RichText.where('body LIKE ?', "%<#{ActionText::Attachment.tag_name}%").includes(:record)
  end

  # @return [String, nil] the html with re-signed nodes, or nil when nothing changed
  def resign(rich_text)
    fragment = ActionText::Fragment.wrap(rich_text.body.to_html)
    touched = false
    fragment.find_all(ActionText::Attachment.tag_name).each do |node|
      sgid = resign_stale_node(rich_text, node['sgid'])
      next if sgid.nil?

      node['sgid'] = sgid
      touched = true
      @result.resigned += 1
    end
    touched ? fragment.to_html : nil
  end

  # @return [String, nil] the new sgid, or nil when the node stays as it is
  def resign_stale_node(rich_text, sgid)
    return if sgid.blank? || signed_with_current_key?(sgid)

    gid = SignedGlobalID.parse(sgid, for: ActionText::Attachable::LOCATOR_NAME, verifier: @old_verifier)
    if gid.nil?
      @result.unreadable += 1
      return
    end

    record = locate(gid)
    return list(:gone, rich_text, gid) if record.nil?
    return list(:refused, rich_text, gid) unless belongs_to_text?(rich_text, record)

    record.attachable_sgid
  end

  # A sgid of the current key whose record is gone raises instead of answering nil; it is
  # still current, and no re-signing would bring its record back.
  def signed_with_current_key?(sgid)
    GlobalID::Locator.locate_signed(sgid, for: ActionText::Attachable::LOCATOR_NAME).present?
  rescue ActiveRecord::RecordNotFound
    true
  end

  def locate(gid)
    GlobalID::Locator.locate(gid)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def belongs_to_text?(rich_text, record)
    if record.is_a?(ActiveStorage::Blob)
      ActiveStorage::Attachment.exists?(record: rich_text, name: 'embeds', blob: record)
    else
      carrier_organisation_id = rich_text.record.try(:organisation_id)
      carrier_organisation_id.present? && record.try(:organisation_id) == carrier_organisation_id
    end
  end

  # Model and id, never gid.to_s: on a SignedGlobalID that signs the id again.
  def list(kind, rich_text, gid)
    @result[kind] << { rich_text_id: rich_text.id, record_type: rich_text.record_type, record_id: rich_text.record_id,
                       target_type: gid.model_name, target_id: gid.model_id }
    nil
  end

  def persist(rich_text, html)
    rich_text.update_column(:body, html)
    carrier = rich_text.record
    return unless carrier.is_a?(Note) && carrier.has_attribute?(:markdown_body)

    carrier.update_column(:markdown_body, Wiki::MarkdownSerializer.new.to_markdown(html))
  end
end

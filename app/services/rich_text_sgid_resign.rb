# frozen_string_literal: true

# One-off repair after a secret_key_base rotation: every <action-text-attachment sgid>
# stored before it was signed with the old key, so Rails renders each image and wiki
# mention as "☒". This re-signs those nodes with the current key, without the old one.
#
# A stale signature proves nothing, so the node itself is never trusted. A node is
# re-signed only when what the app stored NEXT TO the text, while the key was still
# valid, names the same target:
#   * an image: a blob attached to THIS rich text (its embeds);
#   * a wiki mention (notes only): a target among the note's outgoing references.
# The target is read from the sgid's payload when that payload is JSON (never Marshal:
# older sgids are, and an unverified Marshal payload is not to be loaded); an image node
# whose payload cannot be read is matched to an embed by its filename and filesize.
# Everything else is listed with its ids: a blob that is no longer attached was purged
# after the rotation and can only come back from the attachment backup.
#
# Writes with update_column like RichTextEmbedUrlSweep: no validation, no NoteVersion, no
# embeds sync; a note's derived markdown_body is re-derived so the next edit shows no
# spurious diff. Idempotent: a node that resolves is left alone.
#
# Entry point: RichTextSgidResign.call(dry_run: true)
class RichTextSgidResign
  Result = Struct.new(:scanned, :changed, :resigned, :unmatched, :dry_run, keyword_init: true)

  BLOB_MODEL = 'ActiveStorage::Blob'

  def self.call(dry_run: true) = new(dry_run: dry_run).call

  def initialize(dry_run: true)
    @dry_run = dry_run
  end

  def call
    @result = Result.new(scanned: 0, changed: 0, resigned: 0, unmatched: [], dry_run: @dry_run)

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
    ActionText::RichText.where('body LIKE ?', "%<#{ActionText::Attachment.tag_name}%")
                        .includes(:record, embeds_attachments: :blob)
  end

  # @return [String, nil] the html with re-signed nodes, or nil when nothing changed
  def resign(rich_text)
    fragment = ActionText::Fragment.wrap(rich_text.body.to_html)
    stale = fragment.find_all(ActionText::Attachment.tag_name).reject { |node| current?(node['sgid']) }
    return if stale.empty?

    claimed = []
    stale.each do |node|
      target = stored_target(rich_text, node, claimed)
      next if target.nil?

      claimed << target
      node['sgid'] = target.attachable_sgid
      @result.resigned += 1
    end
    claimed.any? ? fragment.to_html : nil
  end

  # A sgid of the current key whose record is gone raises instead of answering nil; it is
  # still current, and no re-signing would bring its record back.
  def current?(sgid)
    return true if sgid.blank?

    GlobalID::Locator.locate_signed(sgid, for: ActionText::Attachable::LOCATOR_NAME).present?
  rescue ActiveRecord::RecordNotFound
    true
  end

  def stored_target(rich_text, node, claimed)
    gid = payload_gid(node['sgid'])
    target, reason =
      if gid.nil? then [embed_by_attributes(rich_text, node, claimed), :unreadable]
      elsif gid.model_name == BLOB_MODEL then [embeds_of(rich_text).find { |blob| blob.id == gid.model_id }, :not_attached]
      else [referenced_target(rich_text.record, gid), :no_reference]
      end
    target || unmatched(rich_text, node, gid, reason)
  end

  # The GlobalID a sgid names, read from its payload WITHOUT verifying it. JSON only: the
  # current envelope ({"_rails": {"data", "pur"}}) and the older self-describing one
  # ({"gid", "purpose"}). Anything else (Marshal) answers nil and is never loaded.
  def payload_gid(sgid)
    message = JSON.parse(Base64.urlsafe_decode64(sgid.to_s.split('--').first.to_s))
    return unless message.is_a?(Hash)

    envelope = message['_rails'].is_a?(Hash) ? message['_rails'] : message
    uri, purpose = envelope.values_at('data', 'pur')
    uri, purpose = envelope.values_at('gid', 'purpose') if uri.nil?
    return unless purpose.to_s == ActionText::Attachable::LOCATOR_NAME

    GlobalID.parse(uri)
  rescue ArgumentError, JSON::ParserError
    nil
  end

  def embeds_of(rich_text) = rich_text.embeds_attachments.map(&:blob)

  # An image node whose payload is not readable: the one embed with its filename and
  # filesize that no other node of the text has taken. Two candidates are no answer.
  def embed_by_attributes(rich_text, node, claimed)
    return if node['filename'].blank? || node['filesize'].blank?

    matches = (embeds_of(rich_text) - claimed).select do |blob|
      blob.filename.to_s == node['filename'] && blob.byte_size.to_s == node['filesize']
    end
    matches.one? ? matches.first : nil
  end

  def referenced_target(carrier, gid)
    return unless carrier.respond_to?(:outgoing_references)

    carrier.outgoing_references.find { |ref| ref.target_type == gid.model_name && ref.target_id == gid.model_id }&.target
  end

  def unmatched(rich_text, node, gid, reason)
    @result.unmatched << { rich_text_id: rich_text.id, record_type: rich_text.record_type, record_id: rich_text.record_id,
                           reason: reason, target_type: gid&.model_name, target_id: gid&.model_id,
                           filename: node['filename'] }
    nil
  end

  def persist(rich_text, html)
    rich_text.update_column(:body, html)
    carrier = rich_text.record
    return unless carrier.is_a?(Note) && carrier.has_attribute?(:markdown_body)

    carrier.update_column(:markdown_body, Wiki::MarkdownSerializer.new.to_markdown(html))
  end
end

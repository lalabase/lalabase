# frozen_string_literal: true

# Writes one entry of the deletion register (AVV § 12 Abs. 7) for an attachment
# that is about to be destroyed. Called from a before_destroy hook on
# ActiveStorage::Attachment — see config/initializers/attachment_deletion_recording.rb
# for why the seam sits there and nowhere else.
class AttachmentDeletionRecorder
  # NEGATIVE list, not a positive one. With a positive list ("these carriers are
  # recorded") a future attachment type would silently fall out of the register
  # and nobody would notice — a gap in a document whose entire purpose is proof.
  # This way the doubtful case is recorded, which is the harmless direction.
  #
  # AiCredentialDocument holds the operator's own contracts with the AI
  # providers (DPAs, terms). No controller's data is ever in them, so recording
  # their deletion would produce entries that serve no audit answer.
  EXCLUDED_RECORD_TYPES = %w[AiCredentialDocument].freeze

  def self.call(...) = new(...).call

  # The carrier resolution is shared with RichTextEmbedGuard (organisation rule for
  # embeds, spike plan E1/D6): ONE place knows that an ActionText::RichText is not the
  # carrier but hangs off it.
  def self.carrier_of(attachment)
    carriers_of([attachment])[attachment]
  end

  # Batched form: one query for the rich texts and one per carrier type instead of one
  # hop per attachment (Prosopite guards the callers).
  # @return [Hash{ActiveStorage::Attachment => carrier or nil}]
  def self.carriers_of(attachments)
    rich_text_ids = attachments.select { |a| a.record_type == 'ActionText::RichText' }.map(&:record_id)
    rich_texts = rich_text_ids.any? ? ActionText::RichText.where(id: rich_text_ids).includes(:record).index_by(&:id) : {}

    attachments.index_with do |attachment|
      if attachment.record_type == 'ActionText::RichText'
        rich_texts[attachment.record_id]&.record
      else
        attachment.record
      end
    rescue StandardError
      nil
    end
  end

  def self.organisation_of(carrier)
    return nil unless carrier.respond_to?(:organisation)

    carrier.organisation
  rescue StandardError
    nil
  end

  def initialize(attachment:)
    @attachment = attachment
  end

  # @return [AttachmentDeletionRecord, nil] the written entry, or nil when the
  #   attachment is out of scope, is not the last reference, or recording failed
  def call
    return if excluded?
    return unless last_reference?

    write_entry
  rescue StandardError => e
    # A failed proof must NEVER prevent a deletion. Otherwise this register
    # would create a new class of files that can no longer be deleted — the
    # exact defect § 12 Abs. 4 just stopped having (see UnattachedBlobPurgeJob).
    # Loud in the log, silent towards the caller.
    Rails.logger.error(
      "[deletion_register] FAILED to record attachment=#{@attachment&.id} " \
      "error=#{e.class}: #{e.message}"
    )
    nil
  end

  private

  def excluded?
    EXCLUDED_RECORD_TYPES.include?(@attachment.record_type)
  end

  # Rails allows several attachments to share one blob. Only the last one going
  # away actually removes the file, so an earlier one must not claim a deletion
  # that did not happen.
  def last_reference?
    !ActiveStorage::Attachment.where(blob_id: @attachment.blob_id)
                              .where.not(id: @attachment.id)
                              .exists?
  end

  def write_entry
    blob = @attachment.blob
    carrier = resolve_carrier
    organisation = organisation_for(carrier)

    AttachmentDeletionRecord.create!(
      organisation_id: organisation&.id,
      organisation_name: organisation&.name,
      user_id: user_id_for(carrier),
      storage_key: blob.key,
      filename: blob.filename.to_s,
      content_type: blob.content_type,
      byte_size: blob.byte_size,
      record_type: carrier&.class&.name || @attachment.record_type,
      deleted_at: Time.current
    )
  end

  # An image inside a rich text hangs off the ActionText::RichText row, not off
  # the ticket or post that owns the text — one resolution step more.
  def resolve_carrier = self.class.carrier_of(@attachment)

  # Never raises: a carrier whose organisation cannot be resolved yields an
  # entry without one ("Organisation unbekannt") rather than a blocked deletion.
  def organisation_for(carrier) = self.class.organisation_of(carrier)

  # User data exports are deliberately not tenant-bound (they span all of a
  # user's organisations), so they are attributed to the user instead.
  def user_id_for(carrier)
    return nil unless carrier.respond_to?(:user_id)

    carrier.user_id
  rescue StandardError
    nil
  end
end

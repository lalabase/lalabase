# frozen_string_literal: true

# Pre-processes the inline display variant of an image that was just embedded in a rich
# text (spike plan Inline-Bilder, D8). ActionText only creates a variant when the first
# browser follows the representation redirect, inside the Puma thread: ten screenshots
# in one ticket are ten vips runs for the first viewer. Enqueued by RichTextEmbedGuard
# after the carrier's commit, once per NEW blob; a purged or non-image blob is a no-op.
class RichTextEmbedVariantJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(blob_id)
    blob = ActiveStorage::Blob.find(blob_id)
    return unless blob.representable? && RichTextEmbeds::IMAGE_CONTENT_TYPES.include?(blob.content_type)

    blob.representation(resize_to_limit: RichTextEmbeds::DISPLAY_LIMIT).processed
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::InvariableError => e
    Rails.logger.warn("RichTextEmbedVariantJob: blob #{blob_id} skipped (#{e.class})")
  end
end

# frozen_string_literal: true

# The ONE owner of every number and list that governs images inside rich texts
# (ticket descriptions, comments, wiki notes). Read by RichTextEmbedGuard (server rule),
# by the editor views (Lexxy's `permitted-attachment-types` and `data-max-bytes`), by
# the browser handler through those data attributes, by the error messages (interpolated
# size) and by the blob partial (variant dimensions). Spike plan Inline-Bilder, E1 and
# decision D5: a second literal of any of these is a drift between browser, server and
# message text; spec/models/action_text/rich_text_embeds_single_owner_spec.rb guards it.
module RichTextEmbeds
  # Product rule, not a security boundary: a file tile does not belong inside running
  # text. Rails identifies the real type on attach anyway and SVG is never served inline.
  IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

  MAX_BYTE_SIZE = 10.megabytes

  # resize_to_limit for the inline display and for gallery tiles (F9); the Lightbox of
  # Paket 2 reads the same constants.
  DISPLAY_LIMIT = [1024, 768].freeze
  GALLERY_LIMIT = [800, 600].freeze
  # Target of the zoom link around every inline image (neo_rich_text_zoom_controller);
  # processed on the first click, not pre-warmed.
  ZOOM_LIMIT = [2048, 2048].freeze

  def self.max_megabytes = MAX_BYTE_SIZE / 1.megabyte

  # Value for the editor's `data-image-types` (read by neo_rich_text_embeds_controller for NEW
  # files). NOT for Lexxy's own `permitted-attachment-types`: Lexxy applies that list also
  # when loading stored content and silently drops every attachment outside it, which would
  # delete existing PDF tiles on the first edit (spec/system/lexxy_trix_roundtrip_spec.rb).
  def self.permitted_attachment_types = IMAGE_CONTENT_TYPES.join(',')
end

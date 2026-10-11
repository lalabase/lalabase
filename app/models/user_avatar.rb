# frozen_string_literal: true

# The ONE owner of every number and list that governs the profile picture
# (doc/user_display_name_avatar_plan.md, S2) — read by the User validation,
# the profile form (accept attribute, hint text with interpolated size), the
# error messages and the variant declaration. Same single-owner idea as
# RichTextEmbeds: a second literal of any of these is drift between browser,
# server and message text.
module UserAvatar
  # User decision 2026-09-04: PNG/JPEG/WebP, max 2 MB. Product rule, not a
  # security boundary — Rails identifies the real type on attach and SVG is
  # never on the list.
  CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze

  MAX_BYTE_SIZE = 2.megabytes

  # Pixel ceiling for anything we hand to libvips inside a request. Bytes alone
  # do not bound the work: 120 bytes of SVG declare 24000x24000 and cost half a
  # gigabyte of RSS, and a flat-colour PNG compresses just as hard. Loose enough
  # for a phone photo (a 24 MP sensor is today's high end), tight enough that a
  # bomb never reaches the crop. Owner of the number, like every rule here.
  MAX_PIXELS = 50_000_000

  # resize_to_fill for the :thumb variant — crisp at the 32px circle on
  # retina displays.
  THUMB_SIZE = [96, 96].freeze

  def self.max_megabytes = MAX_BYTE_SIZE / 1.megabyte

  # Value for the file field's `accept` attribute.
  def self.accept = CONTENT_TYPES.join(',')
end

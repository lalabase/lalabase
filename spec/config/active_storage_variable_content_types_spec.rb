# frozen_string_literal: true

require 'rails_helper'

# Contract: BMP, ICO and PSD are NOT variable. libvips reads those three only through its
# ImageMagick delegation. Our own libvips build (8.16.1 on the servers) carries no magick,
# and Rails 8.0.5.1 blocks the delegation as untrusted regardless (CVE-2026-66066). Left in
# the list, Active Storage still promises a variant for such an attachment and every request
# for one raises Vips::Error instead of falling back to the original file.
#
# Asserted against the effective value, not against config: the config assignment is copied
# into ActiveStorage during boot, so a setting that never arrives would look correct here.
RSpec.describe 'ActiveStorage variable content types' do
  let(:effective) { ActiveStorage.variable_content_types }

  it 'excludes the formats libvips cannot read without ImageMagick' do
    expect(effective).not_to include('image/bmp')
    expect(effective).not_to include('image/vnd.microsoft.icon')
    expect(effective).not_to include('image/vnd.adobe.photoshop')
  end

  it 'still declares the formats we actually serve variants for' do
    %w[image/png image/jpeg image/gif image/webp image/avif image/heic image/heif image/tiff].each do |type|
      expect(effective).to include(type)
    end
  end

  it 'matches the configured list, so the setting really reaches Active Storage' do
    expect(effective).to match_array(Rails.application.config.active_storage.variable_content_types)
  end

  # The list is the mechanism; this is the behaviour it exists for. Active Storage asks
  # #variable? before it promises a variant, and #representable? decides whether a view
  # offers one at all.
  describe 'effect on an attachment' do
    it 'treats a BMP blob as neither variable nor representable' do
      blob = ActiveStorage::Blob.new(filename: 'screenshot.bmp', content_type: 'image/bmp')

      expect(blob.variable?).to be(false)
      expect(blob.representable?).to be(false)
    end

    it 'still treats a PNG blob as variable' do
      blob = ActiveStorage::Blob.new(filename: 'screenshot.png', content_type: 'image/png')

      expect(blob.variable?).to be(true)
    end
  end
end

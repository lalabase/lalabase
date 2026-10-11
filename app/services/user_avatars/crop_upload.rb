# frozen_string_literal: true

# Crops a freshly picked profile picture to the square the user framed with
# the settings tool (doc/user_display_name_avatar_plan.md, crop extension).
# The STORED avatar is the cropped square — the :thumb variant then only
# scales, and every render site inherits the framing for free. The original
# is deliberately not kept: re-framing means re-uploading, the usual contract
# for profile pictures.
#
# Fail-open by design: crop values are user input from hidden fields. Blank,
# malformed or degenerate values return the upload UNCHANGED (the thumb
# variant center-crops as before), out-of-bounds rectangles are clamped into
# the image, and a vips error also falls back to the original. The type/size
# VALIDATION happens afterwards on the model either way.
#
# Fail-open is not the same as trust-open. Everything that decides whether
# libvips gets to look at the bytes AT ALL is checked first, and from the
# bytes themselves (see #croppable? and UserAvatar::MAX_PIXELS). This runs
# synchronously in the request, so an upload that must be refused has to be
# refused BEFORE the decode, not after it.
module UserAvatars
  class CropUpload
    FORMATS = { 'image/png' => 'png', 'image/jpeg' => 'jpg', 'image/webp' => 'webp' }.freeze

    # crop: hash-like with 'x', 'y', 'size' in PIXELS of the original image
    # (the client reads naturalWidth/naturalHeight). Returns an UploadedFile.
    def self.call(upload:, crop:)
      new(upload: upload, crop: crop).call
    end

    def initialize(upload:, crop:)
      @upload = upload
      @crop = crop.to_h.transform_keys(&:to_s)
    end

    def call
      return upload unless croppable?

      x, y, size = clamped_rectangle
      return upload if size.nil?

      processed = ImageProcessing::Vips
                  .source(upload.tempfile.path)
                  .crop(x, y, size, size)
                  .convert(FORMATS.fetch(sniffed_content_type))
                  .call

      ActionDispatch::Http::UploadedFile.new(
        tempfile: processed,
        filename: upload.original_filename,
        type: sniffed_content_type
      )
    rescue Vips::Error
      upload
    end

    private

    attr_reader :upload, :crop

    # The size gate belongs HERE, in front of vips, and not only on the model:
    # cropping shrinks the file, so a rule applied afterwards would measure the
    # CROP instead of what the user sent, and the same picture would be taken
    # with JavaScript and refused without it. Refusing here keeps 2 MB the rule
    # the hint text and the help pages promise; the model then rejects the
    # untouched upload with its own message.
    def croppable?
      upload.respond_to?(:tempfile) && FORMATS.key?(sniffed_content_type) &&
        upload.size.to_i <= UserAvatar::MAX_BYTE_SIZE &&
        %w[x y size].all? { |k| crop[k].to_s.match?(/\A\d+\z/) }
    end

    # NOT upload.content_type. That is a header the CLIENT writes, while vips
    # picks its loader from the BYTES — so trusting the header hands svgload,
    # pdfload or heifload attacker-chosen input inside the request: 120 bytes
    # of SVG declared as image/png decode as a 24000x24000 image. Marcel reads
    # the same bytes ActiveStorage will judge the finished blob by, so the two
    # answers agree, and going through the path leaves the tempfile's own read
    # position alone for whoever reads it next.
    def sniffed_content_type
      @sniffed_content_type ||= Marcel::MimeType.for(Pathname.new(upload.tempfile.path))
    end

    # Pull the requested square inside the actual image: the side never
    # exceeds the shorter dimension, the origin never pushes it past an edge.
    # A degenerate side (0) means "no usable frame" — caller keeps the upload.
    #
    # `.autorot` is load-bearing, not cosmetic. ImageProcessing::Vips
    # auto-rotates on load (image_processing/vips.rb:44) and the browser
    # reports EXIF-oriented naturalWidth/naturalHeight, so a bare
    # new_from_file would clamp against a THIRD, unrotated frame. For a
    # portrait photo off a phone the two axes are swapped and every vertical
    # pan collapses to y=0: the saved circle is the top of the picture, with
    # no error anywhere. Do NOT reach for new_from_file(autorotate: true)
    # instead — that option exists only on the jpeg loader and raises for PNG,
    # which the rescue in #call would swallow into a silent no-crop.
    def clamped_rectangle
      image = Vips::Image.new_from_file(upload.tempfile.path).autorot
      return [nil, nil, nil] if image.width * image.height > UserAvatar::MAX_PIXELS

      size = [crop['size'].to_i, image.width, image.height].min
      return [nil, nil, nil] if size < 1

      x = crop['x'].to_i.clamp(0, image.width - size)
      y = crop['y'].to_i.clamp(0, image.height - size)
      [x, y, size]
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# UserAvatars::CropUpload — the server half of the avatar framing tool. The
# crop values are user input from hidden fields, so the service is fail-open:
# anything unusable returns the upload untouched (the thumb variant keeps its
# center crop), out-of-bounds rectangles are clamped into the image.
#
# Every assertion about a successful crop reads PIXELS, never width and height
# alone. Dimensions cannot tell a correct crop from a wrong one: a service
# that throws the user's x and y away and always cuts the top-left corner
# returns exactly the same 4x4. That gap is why the EXIF bug below shipped.
RSpec.describe UserAvatars::CropUpload do
  let(:red) { [255, 0, 0] }
  let(:green) { [0, 255, 0] }
  let(:blue) { [0, 0, 255] }
  let(:white) { [255, 255, 255] }

  # 8x8, four telling quadrants: red | green over blue | white.
  def quadrants
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/avatar_quadrants.png'), 'image/png')
  end

  # 12x8, three vertical bands: red | green | blue. Non-square on purpose —
  # the clamp is the only place width and height are treated separately, and a
  # square-only suite cannot see a swapped axis.
  def landscape
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/avatar_landscape.png'), 'image/png')
  end

  # Stored 12x8 with EXIF orientation 6, so a browser DISPLAYS 8x12: dark top
  # half, bright bottom half. The shape every phone hands us for a portrait.
  def rotated
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/avatar_rotated.jpg'), 'image/jpeg')
  end

  def call(upload, left:, top:, size:)
    described_class.call(upload: upload, crop: { 'x' => left.to_s, 'y' => top.to_s, 'size' => size.to_s })
  end

  def image(result)
    Vips::Image.new_from_file(result.tempfile.path)
  end

  def dimensions(result)
    [image(result).width, image(result).height]
  end

  def pixel(result, left, top)
    image(result).getpoint(left, top).first(3).map(&:round)
  end

  def fixture_bytes(name)
    File.size(Rails.root.join('spec/fixtures/files', name))
  end

  it 'crops to the framed square and keeps filename and content type' do
    source = quadrants
    result = call(source, left: 2, top: 2, size: 4)

    expect(result).not_to equal(source)
    expect(dimensions(result)).to eq([4, 4])
    expect(result.original_filename).to eq('avatar_quadrants.png')
    expect(result.content_type).to eq('image/png')
  end

  # Declared and real type can disagree without anyone attacking: some browsers
  # guess from the extension. The BYTES decide what is written and what the
  # result announces, so the file, its type and the filename stay consistent.
  it 'writes the format the bytes actually are, not the one the client declared' do
    source = Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/avatar_quadrants.png'), 'image/jpeg'
    )
    result = call(source, left: 0, top: 0, size: 4)

    expect(result.content_type).to eq('image/png')
    expect(image(result).get('vips-loader')).to eq('pngload')
  end

  # The examples a dimensions-only suite is blind to: the same 4x4 comes back
  # for every origin, so only the pixels say whether the frame was honoured.
  describe 'the framed region, not just its size' do
    {
      'top left' => [[0, 0], :red],
      'top right' => [[4, 0], :green],
      'bottom left' => [[0, 4], :blue],
      'bottom right' => [[4, 4], :white]
    }.each do |corner, (origin, colour)|
      it "returns the #{corner} quadrant when that is what was framed" do
        result = call(quadrants, left: origin[0], top: origin[1], size: 4)

        expect(dimensions(result)).to eq([4, 4])
        expect(pixel(result, 0, 0)).to eq(send(colour))
        expect(pixel(result, 3, 3)).to eq(send(colour))
      end
    end
  end

  describe 'clamping (boundary n-1 / n / n+1 on the 8px fixture)' do
    it 'accepts a square inside the image (size 7)' do
      source = quadrants
      result = call(source, left: 0, top: 0, size: 7)

      expect(result).not_to equal(source)
      expect(dimensions(result)).to eq([7, 7])
    end

    it 'accepts the full image (size 8)' do
      source = quadrants
      result = call(source, left: 0, top: 0, size: 8)

      # not_to equal is what makes this example mean something: the source is
      # already 8x8, so the dimensions alone are green even when nothing crops.
      expect(result).not_to equal(source)
      expect(dimensions(result)).to eq([8, 8])
    end

    it 'clamps an oversized square (size 9) to the image' do
      source = quadrants
      result = call(source, left: 0, top: 0, size: 9)

      expect(result).not_to equal(source)
      expect(dimensions(result)).to eq([8, 8])
    end

    it 'pulls an origin past the edge back inside (x 6 with size 4)' do
      result = call(quadrants, left: 6, top: 0, size: 4)

      expect(dimensions(result)).to eq([4, 4])
      # Pulled back to x=4, so this is the top RIGHT quadrant and not a strip
      # of image that does not exist.
      expect(pixel(result, 0, 0)).to eq(green)
    end

    it 'treats a degenerate size (0) as no frame and returns the original' do
      source = quadrants
      expect(call(source, left: 0, top: 0, size: 0)).to equal(source)
    end
  end

  # x is clamped against the width, y against the height. On a square fixture
  # a swapped axis is invisible; on 12x8 it is not.
  describe 'a non-square source' do
    it 'never lets the side exceed the SHORTER dimension (size 12 on 12x8)' do
      source = landscape
      result = call(source, left: 0, top: 0, size: 12)

      expect(result).not_to equal(source)
      expect(dimensions(result)).to eq([8, 8])
    end

    it 'clamps x against the width and y against the height, not one of them twice' do
      result = call(landscape, left: 4, top: 4, size: 8)

      # x=4 fits (12 - 8); y=4 does not (8 - 8 = 0) and is pulled to 0.
      # Clamping y against the WIDTH would leave y=4, vips would refuse the
      # rectangle, and the rescue would turn that into a silent no-crop.
      expect(dimensions(result)).to eq([8, 8])
      expect(pixel(result, 0, 0)).to eq(green)
      expect(pixel(result, 7, 0)).to eq(blue)
    end
  end

  # The regression this suite exists for. ImageProcessing::Vips auto-rotates
  # on load and the browser reports EXIF-oriented naturalWidth/naturalHeight,
  # so the clamp has to measure the ORIENTED image. Measured against the
  # unrotated frame instead, every vertical pan on a portrait photo collapses
  # to y=0 and the saved circle is the top of the picture.
  describe 'an EXIF-rotated photo (stored 12x8, displayed 8x12)' do
    it 'saves the band the user framed, not the top of the stored file' do
      result = call(rotated, left: 0, top: 4, size: 8)

      expect(dimensions(result)).to eq([8, 8])
      # The displayed bottom half is bright (240), the top dark (16). Clamping
      # against the unrotated 12x8 forces y to 0 and the average drops to ~72.
      expect(image(result).avg).to be > 128
    end

    it 'clamps x against the DISPLAYED width instead of refusing the rectangle' do
      source = rotated
      result = call(source, left: 4, top: 0, size: 8)

      # Displayed the picture is 8 wide, so x has nowhere to go and is pulled
      # to 0. Measured against the stored width of 12, x=4 survives, vips is
      # handed a rectangle that runs off an 8px-wide image, and the rescue
      # turns the refusal into a silently uncropped upload.
      expect(result).not_to equal(source)
      expect(dimensions(result)).to eq([8, 8])
      expect(image(result).avg).to be < 128
    end
  end

  # Nothing below reaches libvips at all. These are gates, not fallbacks: the
  # crop runs synchronously in the request, so an upload that has to be
  # refused must be refused BEFORE the decode.
  describe 'what never gets handed to libvips' do
    it 'refuses a file whose BYTES are not a whitelisted image, whatever the client declared' do
      # 120 bytes of SVG announcing itself as image/png. vips picks its loader
      # from the content, so a declared-type check would hand svgload a
      # 24000x24000 canvas inside the request.
      source = Rack::Test::UploadedFile.new(
        Rails.root.join('spec/fixtures/files/avatar_bomb.svg'), 'image/png'
      )

      # The message is the point, not the return value: returning the original
      # is ALSO what the pixel ceiling does, so an assertion on the result
      # alone stays green when the type check goes back to trusting the header.
      expect(Vips::Image).not_to receive(:new_from_file)
      expect(call(source, left: 0, top: 0, size: 4)).to equal(source)
    end

    it 'leaves content types outside the whitelist alone (validation rejects them later)' do
      source = Rack::Test::UploadedFile.new(
        Rails.root.join('spec/fixtures/files/test_image.bmp'), 'image/bmp'
      )

      expect(Vips::Image).not_to receive(:new_from_file)
      expect(call(source, left: 0, top: 0, size: 4)).to equal(source)
    end

    describe 'the size rule, in front of the crop instead of behind it' do
      it 'crops an upload exactly at the limit' do
        stub_const('UserAvatar::MAX_BYTE_SIZE', fixture_bytes('avatar_quadrants.png'))
        source = quadrants

        expect(call(source, left: 0, top: 0, size: 4)).not_to equal(source)
      end

      it 'returns one byte over the limit untouched, so the model measures what the user SENT' do
        stub_const('UserAvatar::MAX_BYTE_SIZE', fixture_bytes('avatar_quadrants.png') - 1)
        source = quadrants

        expect(Vips::Image).not_to receive(:new_from_file)
        expect(call(source, left: 0, top: 0, size: 4)).to equal(source)
      end
    end

    describe 'the pixel ceiling (bytes do not bound the decode)' do
      it 'crops an image exactly at the ceiling' do
        stub_const('UserAvatar::MAX_PIXELS', 8 * 8)
        source = quadrants

        expect(call(source, left: 0, top: 0, size: 4)).not_to equal(source)
      end

      it 'refuses one pixel over it' do
        stub_const('UserAvatar::MAX_PIXELS', (8 * 8) - 1)
        source = quadrants

        expect(call(source, left: 0, top: 0, size: 4)).to equal(source)
      end
    end
  end

  it 'returns the original for malformed values' do
    source = quadrants
    expect(described_class.call(upload: source, crop: { 'x' => 'abc', 'y' => '0', 'size' => '4' }))
      .to equal(source)
  end

  it 'returns the original when crop values are missing' do
    source = quadrants
    expect(described_class.call(upload: source, crop: {})).to equal(source)
  end
end

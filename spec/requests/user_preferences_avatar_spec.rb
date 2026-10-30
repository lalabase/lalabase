# frozen_string_literal: true

require 'rails_helper'

# The profile picture lives in Settings > Profil since 04.09.2026
# (user decision): it belongs next to the name-display choice, and unlike the
# Devise profile this endpoint does NOT demand the current password for a
# picture change. Pins the upload without a password, the blank-field
# no-change semantics, removal, rejection with a re-rendered section, and the
# crop tool's server half (framed square in original pixels).
RSpec.describe 'User preferences avatar', type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  def png_upload
    fixture_file_upload('test_avatar.png', 'image/png')
  end

  # 8x8 with four telling quadrants, so an end-to-end assertion can name the
  # PIXELS that survived instead of only the size of what came back.
  def quadrants_upload
    fixture_file_upload('avatar_quadrants.png', 'image/png')
  end

  # A real PNG header plus padding: Marcel identifies it as image/png, so the
  # whitelist passes and the SIZE rule is the one under test. Ported back from
  # the Devise spec this endpoint replaced — the rule had lost its only
  # end-to-end example, and the model spec stubs byte_size.
  def oversized_png_upload
    file = Tempfile.new(['oversized_avatar', '.png'], binmode: true)
    file.write(Rails.root.join('spec/fixtures/files/test_avatar.png').binread)
    file.write("\0" * UserAvatar::MAX_BYTE_SIZE)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'image/png', original_filename: 'huge.png')
  end

  def stored_pixel(left, top)
    Tempfile.create(['stored', '.png'], binmode: true) do |file|
      file.write(user.reload.avatar.blob.download)
      file.flush
      Vips::Image.new_from_file(file.path).getpoint(left, top).first(3).map(&:round)
    end
  end

  def attach_existing_avatar
    user.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                       filename: 'existing.png', content_type: 'image/png')
    user.save!
  end

  it 'shows the upload spot and the crop tool skeleton in the display section' do
    get display_user_preferences_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('user_preferences.edit.display.avatar.label'))
    expect(response.body).to include('neo-avatar-crop')
    expect(response.body).to include(UserAvatar.accept)
  end

  it 'attaches the picture WITHOUT any password' do
    patch user_preferences_path, params: {
      current_section: 'display',
      preferences: { name_display: 'first_last_initial' },
      user: { avatar: png_upload }
    }

    expect(response).to redirect_to(display_user_preferences_path)
    expect(user.reload.avatar).to be_attached
    expect(user.preference_store.name_display_mode).to eq('first_last_initial')
  end

  it 'stores the framed square when crop values are sent (8px fixture, 4px frame)' do
    patch user_preferences_path, params: {
      current_section: 'display',
      preferences: { name_display: 'first_last_initial' },
      user: { avatar: quadrants_upload, avatar_crop_x: '4', avatar_crop_y: '4', avatar_crop_size: '4' }
    }

    blob = user.reload.avatar.blob
    blob.analyze
    expect(blob.metadata['width']).to eq(4)
    expect(blob.metadata['height']).to eq(4)
    # The size alone cannot tell the framed quadrant from any other one: the
    # bottom right is white, every other corner is a primary colour.
    expect(stored_pixel(0, 0)).to eq([255, 255, 255])
    expect(stored_pixel(3, 3)).to eq([255, 255, 255])
  end

  it 'keeps the existing picture when the file field is submitted blank (no-change semantics)' do
    attach_existing_avatar

    patch user_preferences_path, params: {
      current_section: 'display',
      preferences: { name_display: 'full' },
      user: { avatar: '' }
    }

    expect(user.reload.avatar).to be_attached
  end

  it 'removes the picture via the checkbox' do
    attach_existing_avatar

    patch user_preferences_path, params: {
      current_section: 'display',
      preferences: { name_display: 'full' },
      user: { remove_avatar: '1' }
    }

    expect(user.reload.avatar).not_to be_attached
  end

  it 'rejects a file outside the whitelist and re-renders the section with the error' do
    patch user_preferences_path, params: {
      current_section: 'display',
      preferences: { name_display: 'full' },
      user: { avatar: fixture_file_upload('test_image.bmp', 'image/bmp') }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('user_preferences.edit.display.avatar.label'))
    expect(user.reload.avatar).not_to be_attached
  end

  # BMP is NOT enough on its own. It is stripped from
  # ActiveStorage.variable_content_types, so the preview returns nil before it
  # ever asks the pending blob for a URL — the crash that used to answer this
  # page with a 500 is never reached. The size rule needs a variant-capable
  # type, and it is the rule whose own message could not be shown once before.
  describe 'a picture over the size limit' do
    it 'renders the section with the size message instead of crashing' do
      patch user_preferences_path, params: {
        current_section: 'display',
        preferences: { name_display: 'full' },
        user: { avatar: oversized_png_upload }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("#{UserAvatar.max_megabytes} MB")
      expect(user.reload.avatar).not_to be_attached
    end

    # Cropping shrinks the file, so a rule measured after the crop would take
    # this very upload. The same picture must be refused with and without JS.
    it 'is refused just the same when the crop tool sent a frame' do
      patch user_preferences_path, params: {
        current_section: 'display',
        preferences: { name_display: 'full' },
        user: { avatar: oversized_png_upload, avatar_crop_x: '0', avatar_crop_y: '0', avatar_crop_size: '4' }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("#{UserAvatar.max_megabytes} MB")
      expect(user.reload.avatar).not_to be_attached
    end

    # attached? is true for the merely picked file, so the section would offer
    # to remove a picture this user has never had.
    it 'does not offer to remove a picture that was never stored' do
      patch user_preferences_path, params: {
        current_section: 'display',
        preferences: { name_display: 'full' },
        user: { avatar: oversized_png_upload }
      }

      expect(response.body).not_to include(I18n.t('user_preferences.edit.display.avatar.remove'))
    end
  end

  # A multipart body with a JSON Accept header, not `as: :json`: a file cannot
  # ride in a JSON body, so that variant never reaches the failure at all.
  # `render 'display'` here would look for display.json and raise
  # MissingTemplate — a 500 exactly where the caller asked for an error.
  it 'answers a JSON client with its errors rather than a missing template' do
    patch user_preferences_path,
          params: {
            current_section: 'display',
            preferences: { name_display: 'full' },
            user: { avatar: fixture_file_upload('test_image.bmp', 'image/bmp') }
          },
          headers: { 'Accept' => 'application/json' }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['success']).to be(false)
    expect(response.parsed_body['errors']).to be_present
  end

  # `present?` and `&.key?` both say yes to a scalar, and require(:user).permit
  # then raises NoMethodError on a String. ApplicationController only rescues
  # Pundit, so that was an unhandled 500 on a crafted request.
  it 'survives a :user param that is not a hash' do
    patch user_preferences_path, params: {
      current_section: 'display',
      preferences: { name_display: 'first_last_initial' },
      user: 'not-a-hash'
    }

    expect(response).to redirect_to(display_user_preferences_path)
    expect(user.reload.preference_store.name_display_mode).to eq('first_last_initial')
  end
end

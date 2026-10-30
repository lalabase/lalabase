# frozen_string_literal: true

require 'rails_helper'

# The profile picture MOVED out of the Devise profile into Settings >
# Profil (user decision 04.09.2026): the profile form runs through
# update_with_password and demanded the current password for a picture. This
# file now pins the teardown - no upload spot here, and a smuggled avatar
# param is dead (unpermitted), so the password-gated path cannot come back
# silently. The upload behaviour itself: spec/requests/user_preferences_avatar_spec.rb.
RSpec.describe 'Profile without avatar upload', type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  it 'renders the profile form without an upload spot' do
    get edit_user_registration_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('user[avatar]')
    expect(response.body).not_to include(I18n.t('user_preferences.edit.display.avatar.label'))
  end

  it 'ignores a smuggled avatar param (unpermitted on account_update)' do
    put user_registration_path, params: {
      user: {
        avatar: fixture_file_upload('test_avatar.png', 'image/png'),
        current_password: 'password123'
      }
    }

    expect(user.reload.avatar).not_to be_attached
  end

  it 'still updates the name with the current password (unchanged Devise contract)' do
    put user_registration_path, params: {
      user: { first_name: 'Neu', current_password: 'password123' }
    }

    expect(user.reload.first_name).to eq('Neu')
  end
end

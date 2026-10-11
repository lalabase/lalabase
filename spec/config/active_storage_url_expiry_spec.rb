# frozen_string_literal: true

require 'rails_helper'

# Contract: signed ActiveStorage URLs MUST expire. Without expiry a once-leaked file link
# (logs, referrer, history) opens the file permanently — the core of the file leak. This
# test breaks if someone removes the expiry again (=> never expiring).
RSpec.describe 'ActiveStorage URL expiry (durable leak protection)' do
  it 'configures a finite expiry for signed blob/representation URLs' do
    expiry = Rails.application.config.active_storage.urls_expire_in

    expect(expiry).to be_present
    expect(expiry).to be <= 1.hour
  end
end

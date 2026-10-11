# frozen_string_literal: true

class SessionTouchController < ApplicationController
  # Must run before any callback (including locale selection) loads the user.
  # Devise still checks timeout, but polling must not move last_request_at.
  prepend_before_action :prepare_session_check
  skip_before_action :load_tenant_from_session, raise: false
  skip_before_action :touch_last_seen, if: :checking?

  def show
    last_request_at = warden.session(:user)['last_request_at']
    last_request_at = Time.at(last_request_at).utc if last_request_at.is_a?(Integer)
    last_request_at = Time.parse(last_request_at).utc if last_request_at.is_a?(String)

    render json: {
      expires_at: ((last_request_at || Time.current) + current_user.timeout_in).iso8601,
      timeout_minutes: current_user.session_timeout_minutes,
      user_id: current_user.id,
      csrf_token: form_authenticity_token
    }
  end

  private

  def checking?
    params[:check] == '1'
  end

  def prepare_session_check
    response.headers['Cache-Control'] = 'no-store'
    request.env['devise.skip_trackable'] = true if checking?
  end
end

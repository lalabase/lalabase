# frozen_string_literal: true

# Controller for notification unsubscribe links from emails
#
# PURPOSE:
# Allows users to unsubscribe from specific notification types directly
# from emails, without having to log in.
#
# WHY BUILT THIS WAY:
# - Token-based authentication for secure unsubscribe links
# - No login required for a better UX
# - Granular control per event type
# - Multi-tenancy support
#
# EXAMPLE:
# User clicks the "Unsubscribe" link in an email → lands here → can unsubscribe

class NotificationUnsubscribesController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :verify_token

  def show
    @user = @unsubscribe_data[:user]
    @event_type = @unsubscribe_data[:event_type]
    @organisation = @unsubscribe_data[:organisation]
    @preference = find_or_build_preference
  end

  def update
    @user = @unsubscribe_data[:user]
    @event_type = @unsubscribe_data[:event_type]
    @organisation = @unsubscribe_data[:organisation]

    # Update preference to disable notifications
    preference = find_or_build_preference
    preference.enabled = false
    preference.save!

    redirect_to unsubscribe_notifications_path(token: params[:token]),
                notice: t('flash.notification_unsubscribes.unsubscribed', event_type: @event_type.humanize)
  end

  private

  def verify_token
    token = params[:token]

    begin
      payload = JWT.decode(token, Rails.application.secret_key_base, true, { algorithm: 'HS256' }).first

      # Check if token is expired
      if payload['exp'] && Time.at(payload['exp']) < Time.current
        render_error(t('flash.notification_unsubscribes.link_expired'))
        return
      end

      # Find user and organisation
      user = User.find_by(id: payload['user_id'])
      organisation = Organisation.find_by(id: payload['organisation_id'])

      unless user && organisation
        render_error(t('flash.notification_unsubscribes.link_invalid'))
        return
      end

      @unsubscribe_data = {
        user: user,
        event_type: payload['event_type'],
        organisation: organisation
      }
    rescue JWT::DecodeError, JWT::ExpiredSignature
      render_error(t('flash.notification_unsubscribes.link_error'))
    rescue StandardError => e
      Rails.logger.error "Unsubscribe error: #{e.message}"
      render_error(t('flash.notification_unsubscribes.processing_error'))
    end
  end

  def find_or_build_preference
    NotificationPreference.find_or_initialize_by(
      user: @user,
      organisation: @organisation,
      event_type: @event_type,
      channel: 'email',
      scope_type: nil,
      scope_id: nil
    )
  end

  def render_error(message)
    render plain: message, status: :bad_request
  end
end

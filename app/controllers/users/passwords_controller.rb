# frozen_string_literal: true

# app/controllers/users/passwords_controller.rb
class Users::PasswordsController < Devise::PasswordsController
  # Werkstatt split screen for both password pages. Devise::PasswordsController
  # has no other actions than new/create/edit/update, so the branch this used to
  # carry ("application for anything else") described a case that cannot happen.
  layout 'application_auth'

  # Track password reset request
  def create
    super do |resource|
      resource.track_password_reset_request(request: request) if resource.persisted? && resource.reset_password_token.present?
    end
  end

  # Track successful password reset
  def update
    super do |resource|
      resource.track_password_reset_completion(request: request) if resource.errors.empty? && resource.persisted?
    end
  end
end

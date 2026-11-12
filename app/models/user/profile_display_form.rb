# frozen_string_literal: true

class User < ApplicationRecord
  # Form object for what the others see of a person, on the account's profile tab
  # (Users::RegistrationsController#update_display): the profile picture and which
  # email is shown (User::EmailDisplay).
  #
  # Its own form and no part of Devise's account update on purpose: that one runs
  # through update_with_password and demanded the current password for a picture
  # (user decision 04.09.2026). The login address and the password stay behind it.
  #
  # Carries the form's parsing quirks, which is why it lives here and not in the model:
  # an untouched file field arrives as "" (and the has_one_attached writer reads an
  # empty string as DELETE), and the crop tool's three hidden fields belong to the
  # upload, not to the user.
  #
  # ONE update for all of it, so a refused part leaves nothing half saved. Mass
  # assignment through user.update on purpose: only that staged path runs the
  # acceptable_avatar validation, a direct avatar.attach on a persisted record would
  # bypass it. Works with ActionController::Parameters; the return value is the
  # truthiness of the save, the errors are the user's.
  class ProfileDisplayForm
    AVATAR_FIELDS = %i[avatar remove_avatar avatar_crop_x avatar_crop_y avatar_crop_size].freeze
    EMAIL_FIELDS = %i[email_visibility contact_email].freeze

    def initialize(user)
      @user = user
    end

    # fields: params[:user], whatever the client sent. Anything but a parameters
    # hash (a scalar, nothing) changes nothing and is no error.
    def update(fields)
      return true unless fields.is_a?(ActionController::Parameters)

      changes = avatar_changes(fields).merge(fields.permit(*EMAIL_FIELDS).to_h)
      changes.empty? || user.update(changes)
    end

    private

    attr_reader :user

    def avatar_changes(fields)
      permitted = fields.permit(*AVATAR_FIELDS)
      crop = { x: permitted.delete(:avatar_crop_x), y: permitted.delete(:avatar_crop_y),
               size: permitted.delete(:avatar_crop_size) }
      # Blank means "no change", see above.
      permitted.delete(:avatar) if permitted[:avatar].blank?
      permitted[:avatar] = UserAvatars::CropUpload.call(upload: permitted[:avatar], crop: crop) if permitted[:avatar].present?
      permitted.to_h
    end
  end
end

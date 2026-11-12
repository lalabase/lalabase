# frozen_string_literal: true

class UserPreferencesController < ApplicationController
  include UserPreferencesHelper

  before_action :authenticate_user!
  skip_before_action :load_tenant_from_session

  # The sections of the one preferences page (user_preferences/edit). A save names its
  # section in `current_section` and touches that section's values only; the name is
  # also the anchor an answer leads back to, so only these are accepted.
  SECTIONS = %w[general display tickets meetings datetime language session].freeze

  # GET /user_preferences/edit
  # One page for every section since 2026-11-12. The old section addresses
  # (/user_preferences/tickets, ...) redirect to its anchors (config/routes.rb).
  def edit
    @user = current_user
    ensure_preferences_structure
  end

  # PATCH /user_preferences
  # Answers a form with a redirect to the section's anchor, and a script (the page's
  # autosave, the pagination's page size, the ticket's collapse choice) with JSON:
  # `success`, on success `items_per_page` and `reload` (true when the page the reader
  # looks at is stale now: another language, another session length in the layout).
  def update
    # Determine which section the user is actively editing (hidden field has priority)
    section = determine_current_section_from_params

    # Session length: a column on users, not in the preferences JSON.
    return update_session_timeout if section == 'session' && user_param_hash? && params[:user].key?(:session_timeout_minutes)

    # Profile picture (display section): an attachment on users, not a JSONB
    # pref. Lives HERE and not in the Devise profile on purpose - Devise's
    # update_with_password demanded the current password for every picture
    # change (user decision 04.09.2026). Applied BEFORE the JSONB prefs so one
    # submit can carry both; a failed picture keeps the page rendered with
    # the model's own error message.
    # The picture and which email the others see (User::EmailDisplay) are
    # columns and an attachment on users, saved here in ONE update, so a
    # refused part leaves nothing half saved.
    return if section == 'display' && user_param_hash? && !apply_display_update

    return update_language if section == 'language' && user_param_hash? && params[:user].key?(:language_preference)

    if User::PreferencesForm.new(current_user).update(preference_params)
      respond_saved(section)
    else
      respond_to do |format|
        format.json { render json: { success: false, errors: current_user.errors.full_messages }, status: :unprocessable_entity }
        format.html do
          flash.now[:alert] = t('user_preferences.settings_update_failed')
          render_page_again
        end
      end
    end
  end

  private

  def update_session_timeout
    new_timeout = params[:user][:session_timeout_minutes].to_i
    changed = new_timeout != current_user.session_timeout_minutes
    if current_user.update(session_timeout_minutes: new_timeout)
      # The layout counts down to the old length until it is rendered again.
      respond_saved('session', reload: changed)
    else
      respond_refused('session', alert: t('user_preferences.settings_update_failed'))
    end
  end

  def update_language
    new_lang = user_params[:language_preference]
    # No change: nothing to write, and nothing on the page is stale.
    return respond_saved('language') unless new_lang.present? && new_lang != current_user.language_preference

    if current_user.update(user_params)
      I18n.locale = current_user.language_preference.to_sym
      respond_saved('language', notice: t('user_preferences.language_updated'), reload: true)
    else
      respond_refused('language', alert: t('user_preferences.language_update_failed'))
    end
  end

  # A script that is told to reload gets the notice on the page it loads next: the
  # line beside the section's heading does not survive the reload.
  def respond_saved(section, notice: t('user_preferences.settings_updated'), reload: false)
    respond_to do |format|
      format.json do
        flash[:notice] = notice if reload
        render json: { success: true, reload: reload, items_per_page: current_user.items_per_page_preference }
      end
      format.html { redirect_to preferences_section_path(section), notice: notice }
    end
  end

  def respond_refused(section, alert:)
    respond_to do |format|
      format.json do
        render json: { success: false, errors: current_user.errors.full_messages.presence || [alert] },
               status: :unprocessable_entity
      end
      format.html { redirect_to preferences_section_path(section), alert: alert }
    end
  end

  # The whole page again after a refused save (422), with what the user holds now.
  def render_page_again
    @user = current_user
    ensure_preferences_structure
    render :edit, status: :unprocessable_entity
  end

  def user_params
    params.require(:user).permit(:language_preference, :session_timeout_minutes)
  end

  # The display section's own columns: the profile picture and which email the
  # others see. Returns true when the rest of the update may proceed; renders
  # the section itself (422) on a validation failure. Mass assignment through
  # current_user.update on purpose: only that staged path runs the
  # acceptable_avatar validation - a direct avatar.attach on a persisted record
  # would bypass it. Login address and password stay behind the Devise
  # profile's current-password gate.
  def apply_display_update
    permitted = avatar_changes.merge(params.require(:user).permit(:email_visibility, :contact_email).to_h)
    return true if permitted.empty?
    return true if current_user.update(permitted)

    render_display_errors
  end

  def avatar_changes
    permitted = params.require(:user).permit(:avatar, :remove_avatar, :avatar_crop_x, :avatar_crop_y, :avatar_crop_size)
    crop = { x: permitted.delete(:avatar_crop_x), y: permitted.delete(:avatar_crop_y),
             size: permitted.delete(:avatar_crop_size) }
    # An untouched file field submits "", and the has_one_attached writer
    # treats an empty string as DELETE - blank means "no change".
    permitted.delete(:avatar) if permitted[:avatar].blank?
    permitted[:avatar] = UserAvatars::CropUpload.call(upload: permitted[:avatar], crop: crop) if permitted[:avatar].present?
    permitted.to_h
  end

  # The page again, with the model's own error messages (422).
  # Returns false, the answer of a refused update.
  def render_display_errors
    # respond_to, not a bare render: this controller answers JSON too (see the
    # preferences branch above), and a bare render on a JSON request looks
    # for edit.json and raises MissingTemplate — a 500 exactly where the
    # caller asked for an error message.
    respond_to do |format|
      format.json do
        render json: { success: false, errors: current_user.errors.full_messages },
               status: :unprocessable_entity
      end
      format.html do
        flash.now[:alert] = current_user.errors.full_messages.to_sentence
        render_page_again
      end
    end
    false
  end

  # params[:user] is whatever the client sent. Both `present?` and `&.key?`
  # say yes to a scalar (`?user=foo`), and require(:user).permit then raises
  # NoMethodError on a String — an unhandled 500, because ApplicationController
  # only rescues Pundit. Every branch that treats :user as a hash asks this
  # instead, so the shape is checked in ONE place rather than four.
  def user_param_hash?
    params[:user].is_a?(ActionController::Parameters)
  end

  def known_section(value)
    SECTIONS.find { |section| section == value } || 'general'
  end

  def determine_current_section_from_params
    # First, check the hidden field that tells us which section was active
    return known_section(params[:current_section]) if params[:current_section].present?

    # Fallback: Check which specific parameters were actually submitted by the user
    if params[:preferences]
      # Check for datetime-specific parameters
      date_params = params[:preferences][:date_display]
      if date_params && (
        date_params[:global_format].present? ||
        date_params[:custom_format].present? ||
        date_params[:areas].present? ||
        date_params[:areas_custom].present?
      )
        return 'datetime'
      end

      # Check for ticket-specific parameters (timeline order, description collapse)
      if params[:preferences][:post_direction].present? ||
         params[:preferences][:description_collapse].present?
        return 'tickets'
      end

      # Check for meetings-specific parameters (detection mode, Slice 5)
      return 'meetings' if params[:preferences][:meeting_detection_mode].present?

      # Check for the name display mode (display section)
      return 'display' if params[:preferences][:name_display].present?

      # Check for general-specific parameters
      return 'general' if params[:preferences][:items_per_page].present?
    end

    # Only check for language preference if no current_section was provided
    return 'language' if user_param_hash? && params[:user].key?(:language_preference)

    return 'session' if user_param_hash? && params[:user].key?(:session_timeout_minutes)

    'general' # default
  end

  def ensure_preferences_structure
    current_user.preferences ||= {}
    current_user.preferences['date_display'] ||= {
      'global_format' => 'relative',
      'custom_format' => '%d.%m.%Y %H:%M',
      'areas' => {
        'posts' => 'inherit',
        'ticket_header' => 'inherit',
        'ticket_list_large' => 'inherit',
        'ticket_list_compact' => 'inherit',
        'activity_logs' => 'inherit'
      }
    }
    current_user.preferences['items_per_page'] ||= 20
    current_user.preferences['post_direction'] ||= 'chronological'
  end

  # The permit structure is mirrored in spec/models/user/preferences_form_spec.rb
  # (permitted_params) — keep both in sync when changing it.
  def preference_params
    return {} unless params[:preferences].present?

    permitted = params.require(:preferences).permit(
      :items_per_page,
      :post_direction,
      :description_collapse,
      :meeting_detection_mode,
      :name_display,
      date_display: [
        :global_format,
        :custom_format,
        :use_global_for_all,
        { areas: %i[
            posts
            ticket_header
            ticket_list_large
            ticket_list_compact
            activity_logs
          ],
          areas_custom: %i[
            posts
            ticket_header
            ticket_list_large
            ticket_list_compact
            activity_logs
          ] }
      ]
    )

    # The preferences JSONB has no model-level validation, so this is the only
    # write gate: drop unknown values before they reach the store, so a crafted
    # PATCH cannot poison a preference. The store readers additionally
    # normalise on read (defense in depth). Was two hand-rolled twin gates; the
    # third whitelisted preference (name_display) triggered the unification the
    # old comment demanded.
    WHITELISTED_PREFERENCES.each do |key, allowed_values|
      permitted.delete(key) if permitted.key?(key) && allowed_values.exclude?(permitted[key])
    end

    permitted
  end

  # Enum-like preferences whose allowed values are pinned by a store constant.
  # The store constant is also the read-side whitelist — one owner per list.
  WHITELISTED_PREFERENCES = {
    description_collapse: User::PreferenceStore::DESCRIPTION_COLLAPSE_VALUES,
    meeting_detection_mode: User::PreferenceStore::MEETING_DETECTION_MODES,
    name_display: User::PreferenceStore::NAME_DISPLAY_MODES
  }.freeze
end

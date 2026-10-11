# frozen_string_literal: true

class UserPreferencesController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :load_tenant_from_session

  # The section name selects the template to render, so only these are accepted.
  SECTIONS = %w[general display tickets meetings datetime language session].freeze

  # GET /user_preferences/edit
  # GET /user_preferences/general
  # GET /user_preferences/datetime
  # GET /user_preferences/language
  def edit
    @user = current_user
    # Looked up inline (not via known_section) so Brakeman sees the allowlist.
    @current_section = SECTIONS.find { |section| section == params[:section] } || 'general'
    ensure_preferences_structure
    render @current_section
  end

  # PATCH /user_preferences
  def update
    # Determine which section the user is actively editing (hidden field has priority)
    section = determine_current_section_from_params

    # Handle session timeout preference separately (column on users, not in preferences JSON)
    if section == 'session' && user_param_hash? && params[:user].key?(:session_timeout_minutes)
      new_timeout = params[:user][:session_timeout_minutes].to_i
      if current_user.update(session_timeout_minutes: new_timeout)
        redirect_to session_user_preferences_path, notice: t('user_preferences.settings_updated')
      else
        redirect_to session_user_preferences_path, alert: t('user_preferences.settings_update_failed')
      end
      return
    end

    # Profile picture (display section): an attachment on users, not a JSONB
    # pref. Lives HERE and not in the Devise profile on purpose - Devise's
    # update_with_password demanded the current password for every picture
    # change (user decision 04.09.2026). Applied BEFORE the JSONB prefs so one
    # submit can carry both; a failed picture keeps the section rendered with
    # the model's own error message.
    return if section == 'display' && user_param_hash? && !apply_avatar_update

    # Handle language preference separately
    if section == 'language' && user_param_hash? && params[:user].key?(:language_preference)
      new_lang = user_params[:language_preference]
      if new_lang.present? && new_lang != current_user.language_preference
        if current_user.update(user_params)
          I18n.locale = current_user.language_preference.to_sym
          redirect_to language_user_preferences_path, notice: t('user_preferences.language_updated')
        else
          redirect_to language_user_preferences_path, alert: t('user_preferences.language_update_failed')
        end
      else
        # No change – redirect back to language section with generic success
        redirect_to language_user_preferences_path, notice: t('user_preferences.settings_updated')
      end
      return
    end

    if User::PreferencesForm.new(current_user).update(preference_params)
      redirect_path = determine_redirect_path

      respond_to do |format|
        format.json { render json: { success: true, items_per_page: current_user.items_per_page_preference } }
        format.html { redirect_to redirect_path, notice: t('user_preferences.settings_updated') }
      end
    else
      respond_to do |format|
        format.json { render json: { success: false, errors: current_user.errors.full_messages }, status: :unprocessable_entity }
        format.html do
          flash.now[:alert] = t('user_preferences.settings_update_failed')
          @user = current_user
          @current_section = determine_current_section_from_params
          ensure_preferences_structure
          render @current_section, status: :unprocessable_entity
        end
      end
    end
  end

  private

  def user_params
    params.require(:user).permit(:language_preference, :session_timeout_minutes)
  end

  # Attach/remove the profile picture from the display section. Returns true
  # when the rest of the update may proceed; renders the section itself (422)
  # on a validation failure. Mass assignment through current_user.update on
  # purpose: only that staged path runs the acceptable_avatar validation -
  # a direct avatar.attach on a persisted record would bypass it.
  def apply_avatar_update
    permitted = params.require(:user).permit(:avatar, :remove_avatar, :avatar_crop_x, :avatar_crop_y, :avatar_crop_size)
    crop = { x: permitted.delete(:avatar_crop_x), y: permitted.delete(:avatar_crop_y),
             size: permitted.delete(:avatar_crop_size) }
    # An untouched file field submits "", and the has_one_attached writer
    # treats an empty string as DELETE - blank means "no change".
    permitted.delete(:avatar) if permitted[:avatar].blank?
    return true if permitted.empty?

    permitted[:avatar] = UserAvatars::CropUpload.call(upload: permitted[:avatar], crop: crop) if permitted[:avatar].present?
    return true if current_user.update(permitted)

    # respond_to, not a bare render: this controller answers JSON too (see the
    # preferences branch above), and `render 'display'` on a JSON request looks
    # for display.json and raises MissingTemplate — a 500 exactly where the
    # caller asked for an error message.
    respond_to do |format|
      format.json do
        render json: { success: false, errors: current_user.errors.full_messages },
               status: :unprocessable_entity
      end
      format.html do
        flash.now[:alert] = current_user.errors.full_messages.to_sentence
        @user = current_user
        @current_section = 'display'
        ensure_preferences_structure
        render 'display', status: :unprocessable_entity
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

  def redirect_path
    params[:redirect_to].presence || root_path
  end

  def determine_redirect_path
    section = determine_current_section_from_params
    case section
    when 'tickets'
      tickets_user_preferences_path
    when 'meetings'
      meetings_user_preferences_path
    when 'datetime'
      datetime_user_preferences_path
    when 'display'
      display_user_preferences_path
    when 'language'
      language_user_preferences_path
    when 'session'
      session_user_preferences_path
    else
      general_user_preferences_path
    end
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

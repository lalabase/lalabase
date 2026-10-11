# frozen_string_literal: true

# Persists the user-global cockpit (organisations#select) settings. Runs WITHOUT a tenant — the
# cockpit is cross-org, like UserPreferencesController. This is a trivial single write (no Activity
# tracking, no side-effect jobs), so it stays a thin controller per the Actor seam rule.
#
# The preferences JSONB has NO model-level validation, so this controller is the write-side gate:
# it drops unknown importance/layout values and coerces the checkboxes to real booleans before they
# reach the store. The PreferenceStore getters normalise again on read (defense in depth).
class CockpitSettingsController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :load_tenant_from_session

  # PATCH/PUT /cockpit_settings
  def update
    current_user.preference_store.update(cockpit_params)
    redirect_to select_organisation_path, notice: t('cockpit_settings.updated')
  end

  private

  # Whitelist + normalise into the flat preference keys. Unknown importance/layout are simply not
  # written (the getter falls back to the default on read); checkboxes become true/false so no raw
  # string lands in the JSONB.
  def cockpit_params
    raw = params.require(:cockpit).permit(:show_actions, :show_todos, :importance, :layout)

    {
      'cockpit_show_actions' => boolean_param(raw[:show_actions]),
      'cockpit_show_todos' => boolean_param(raw[:show_todos])
    }.merge(whitelisted_choices(raw))
  end

  # Only valid importance/layout values are written; unknown ones are omitted entirely so the store
  # falls back to its default on read (rather than persisting garbage).
  def whitelisted_choices(raw)
    choices = {}
    choices['cockpit_importance'] = raw[:importance] if valid_importance?(raw[:importance])
    choices['cockpit_layout'] = raw[:layout] if valid_layout?(raw[:layout])
    choices
  end

  def valid_importance?(value)
    User::PreferenceStore::COCKPIT_IMPORTANCE_LEVELS.include?(value)
  end

  def valid_layout?(value)
    User::PreferenceStore::COCKPIT_LAYOUTS.include?(value)
  end

  # Checkbox -> boolean. Absent (unchecked, no param) and "0"/false -> false; "1"/true -> true.
  def boolean_param(value)
    ActiveModel::Type::Boolean.new.cast(value) || false
  end
end

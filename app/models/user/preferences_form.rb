# frozen_string_literal: true

class User < ApplicationRecord
  # Form object for the user preferences form (UserPreferencesController#update).
  # Carries the HTTP form parsing quirk from the former User#update_preferences:
  # the use_global_for_all checkbox ('1') sets all five areas to 'inherit'.
  # That is form parsing and therefore lives here instead of in the
  # PreferenceStore. Works identically with ActionController::Parameters and
  # plain hashes; the return value is the truthiness of user.save (the
  # controller branches on it, including the JSON error path).
  class PreferencesForm
    def initialize(user)
      @user = user
    end

    def update(prefs)
      # Handle use_global_for_all logic
      if prefs.dig('date_display', 'use_global_for_all') == '1'
        # If use_global_for_all is checked, set all areas to inherit
        prefs['date_display']['areas'] = {
          'posts' => 'inherit',
          'ticket_header' => 'inherit',
          'ticket_list_large' => 'inherit',
          'ticket_list_compact' => 'inherit',
          'activity_logs' => 'inherit'
        }
      end

      user.preference_store.update(prefs)
    end

    private

    attr_reader :user
  end
end

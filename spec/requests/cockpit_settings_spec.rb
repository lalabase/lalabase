# frozen_string_literal: true

require 'rails_helper'

# CockpitSettingsController persists the user-global cockpit settings. It runs WITHOUT a tenant
# (skip_before_action :load_tenant_from_session), like UserPreferencesController. The preferences
# JSONB has no model validation, so the controller is the write-side gate (whitelist + boolean
# coercion); these specs pin that gate.
RSpec.describe 'CockpitSettings', type: :request do
  let(:user) { create(:user) }

  before { sign_in user }
  after { ActsAsTenant.current_tenant = nil }

  def patch_settings(cockpit)
    patch cockpit_settings_path, params: { cockpit: cockpit }
  end

  it 'is reachable WITHOUT a tenant and redirects to the cockpit' do
    ActsAsTenant.current_tenant = nil
    patch_settings(importance: 'all', layout: 'rows_compact', show_actions: '1', show_todos: '1')

    expect(response).to redirect_to(select_organisation_path)
  end

  it 'persists a valid set of settings' do
    patch_settings(importance: 'all', layout: 'rows_detailed', show_actions: '0', show_todos: '1')

    store = user.reload.preference_store
    expect(store.cockpit_importance).to eq('all')
    expect(store.cockpit_layout).to eq('rows_detailed')
    expect(store.cockpit_show_actions?).to be(false)
    expect(store.cockpit_show_todos?).to be(true)
  end

  describe 'whitelist (the controller is the only write gate)' do
    it 'drops an unknown importance value (store keeps the default on read)' do
      patch_settings(importance: 'garbage', layout: 'stacked', show_actions: '1', show_todos: '1')
      expect(user.reload.preference_store.cockpit_importance).to eq('important')
    end

    it 'drops an unknown layout value' do
      patch_settings(importance: 'all', layout: 'pizza', show_actions: '1', show_todos: '1')
      expect(user.reload.preference_store.cockpit_layout).to eq('stacked')
    end

    it 'coerces checkbox booleans, never storing a raw string' do
      patch_settings(importance: 'all', layout: 'stacked', show_actions: '0', show_todos: '1')

      reloaded = user.reload.preferences
      expect(reloaded['cockpit_show_actions']).to be(false)
      expect(reloaded['cockpit_show_todos']).to be(true)
    end
  end

  it "writes only the current user's preferences, never another user's" do
    other = create(:user)
    patch_settings(importance: 'all', layout: 'rows_compact', show_actions: '1', show_todos: '1')

    expect(user.reload.preference_store.cockpit_importance).to eq('all')
    expect(other.reload.preference_store.cockpit_importance).to eq('important') # untouched default
  end

  context 'when not signed in' do
    it 'redirects to the login page' do
      sign_out user
      patch_settings(importance: 'all', layout: 'stacked', show_actions: '1', show_todos: '1')

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end

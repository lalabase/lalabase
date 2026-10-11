# frozen_string_literal: true

require 'rails_helper'

# Specs for User::PreferencesForm — the controller-facing form object for the
# user preferences screen, extracted from the User god-class (user.rb split,
# slice 1/7). It is the WRITE side that UserPreferencesController#update drives;
# the read side lives in User::PreferenceStore.
#
# WHAT THIS GUARDS
# Pure refactoring, so these are CHARACTERIZATION tests. The form must treat
# real ActionController::Parameters exactly like a plain hash, deep-merge nested
# date_display preferences, expand the use_global_for_all checkbox, and return
# user.save's truthiness so the controller's 422 error path keeps working.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO
#   - the permitted_params helper mirrors the controller's require+permit list
#     on purpose (duplicated, with a sync note) so the Parameters-vs-hash parity
#     is tested against the EXACT shape the controller passes;
#   - use_global_for_all is asserted over all five areas via the '1' string,
#     because the checkbox value arrives as a string, not a boolean;
#   - the "integration: form writes feed the store readers" block exists because
#     the write list (form) and the read list (store) are two separate copies of
#     the five-area set — these round-trips break the moment the two drift apart,
#     a divergence the isolated unit examples cannot see.
RSpec.describe User::PreferencesForm, type: :model do
  let(:user) { create(:user) }
  let(:form) { described_class.new(user) }

  # Builds ActionController::Parameters exactly like
  # UserPreferencesController#preference_params (require + permit) — the form
  # object must treat Parameters identically to plain hashes.
  # Deliberate duplication of the permit structure (the controller carries a
  # mirror note): keep both in sync when preference_params changes.
  def permitted_params(raw)
    ActionController::Parameters.new('preferences' => raw).require('preferences').permit(
      :items_per_page,
      :post_direction,
      :description_collapse,
      :meeting_detection_mode,
      :name_display,
      date_display: [
        :global_format,
        :custom_format,
        :use_global_for_all,
        { areas: %i[posts ticket_header ticket_list_large ticket_list_compact activity_logs],
          areas_custom: %i[posts ticket_header ticket_list_large ticket_list_compact activity_logs] }
      ]
    )
  end

  describe '#update' do
    context 'with a plain hash' do
      it 'merges preferences and returns true' do
        user.update!(preferences: { 'items_per_page' => 20 })

        result = form.update({ 'items_per_page' => 50, 'post_direction' => 'reverse' })

        expect(result).to be true
        expect(user.reload.preferences).to include(
          'items_per_page' => 50,
          'post_direction' => 'reverse'
        )
      end

      it 'deep merges nested date_display preferences' do
        user.update!(preferences: {
                       'date_display' => {
                         'global_format' => 'relative',
                         'areas' => { 'posts' => 'inherit' }
                       }
                     })

        form.update({
                      'date_display' => {
                        'global_format' => 'german',
                        'areas' => { 'ticket_header' => 'relative' }
                      }
                    })

        expect(user.reload.preferences.dig('date_display', 'global_format')).to eq('german')
        expect(user.preferences.dig('date_display', 'areas')).to eq(
          'posts' => 'inherit',
          'ticket_header' => 'relative'
        )
      end
    end

    context 'with ActionController::Parameters' do
      it 'behaves identically to a plain hash' do
        user.update!(preferences: {
                       'date_display' => { 'custom_format' => '%Y/%m/%d' }
                     })

        params = permitted_params(
          'items_per_page' => '50',
          'date_display' => { 'global_format' => 'german' }
        )
        result = form.update(params)

        expect(result).to be true
        expect(user.reload.preferences).to include('items_per_page' => '50')
        expect(user.preferences.dig('date_display', 'global_format')).to eq('german')
        expect(user.preferences.dig('date_display', 'custom_format')).to eq('%Y/%m/%d')
      end
    end

    context 'with the use_global_for_all checkbox' do
      it "sets all five areas to inherit when checked ('1') via Parameters" do
        user.update!(preferences: {
                       'date_display' => { 'areas' => { 'posts' => 'german' } }
                     })

        params = permitted_params(
          'date_display' => { 'global_format' => 'relative', 'use_global_for_all' => '1' }
        )
        result = form.update(params)

        expect(result).to be true
        expect(user.reload.preferences.dig('date_display', 'areas')).to eq(
          'posts' => 'inherit',
          'ticket_header' => 'inherit',
          'ticket_list_large' => 'inherit',
          'ticket_list_compact' => 'inherit',
          'activity_logs' => 'inherit'
        )
        expect(user.preferences.dig('date_display', 'global_format')).to eq('relative')
      end

      it "sets all five areas to inherit when checked ('1') via plain hash" do
        user.update!(preferences: {
                       'date_display' => { 'areas' => { 'activity_logs' => 'international' } }
                     })

        form.update({ 'date_display' => { 'use_global_for_all' => '1' } })

        expect(user.reload.preferences.dig('date_display', 'areas')).to eq(
          'posts' => 'inherit',
          'ticket_header' => 'inherit',
          'ticket_list_large' => 'inherit',
          'ticket_list_compact' => 'inherit',
          'activity_logs' => 'inherit'
        )
      end

      it "leaves areas untouched when the checkbox is not '1'" do
        user.update!(preferences: {
                       'date_display' => { 'areas' => { 'posts' => 'german' } }
                     })

        params = permitted_params(
          'date_display' => { 'global_format' => 'relative', 'use_global_for_all' => '0' }
        )
        form.update(params)

        expect(user.reload.preferences.dig('date_display', 'areas')).to eq('posts' => 'german')
      end

      it 'leaves areas untouched when the checkbox is absent' do
        user.update!(preferences: {
                       'date_display' => { 'areas' => { 'posts' => 'german' } }
                     })

        form.update({ 'date_display' => { 'global_format' => 'international' } })

        expect(user.reload.preferences.dig('date_display', 'areas')).to eq('posts' => 'german')
      end
    end

    context 'when saving fails' do
      it 'returns false (controller error path contract)' do
        allow(user).to receive(:save).and_return(false)

        expect(form.update({ 'items_per_page' => 30 })).to be false
      end
    end
  end

  describe 'integration: form writes feed the store readers' do
    # End-to-end over the seam the app actually renders from:
    # PreferencesForm -> PreferenceStore -> readers/facades. The isolated unit
    # examples cannot see drift between the form's write shape and the store's
    # read paths — these examples break exactly when the two sides diverge.

    it 'a form-written post_direction flips the timeline reader' do
      expect { form.update({ 'post_direction' => 'reverse' }) }
        .to change { user.preference_store.prefers_reverse_timeline? }.from(false).to(true)
    end

    it 'a form-written meeting_detection_mode reaches the store reader (Gespräche Slice 5)' do
      expect { form.update(permitted_params('meeting_detection_mode' => 'ai')) }
        .to change { user.preference_store.meeting_detection_mode_preference }.from('offline').to('ai')
    end

    it 'a form-written name_display reaches the store reader (name display S1)' do
      expect { form.update(permitted_params('name_display' => 'initial_last')) }
        .to change { user.preference_store.name_display_mode }.from('full').to('initial_last')
    end

    it 'a form-written global format drives the strftime facade on the user' do
      form.update(permitted_params('date_display' => { 'global_format' => 'german' }))
      expect(user.date_strftime_format).to eq('%d.%m.%Y %H:%M')
    end

    it 'a form-written items_per_page reaches the pagination facade as integer' do
      # HTTP form values arrive as strings; the facade is the integer the
      # controller's JSON success path renders back.
      form.update(permitted_params('items_per_page' => '25'))
      expect(user.items_per_page_preference).to eq(25)
    end

    it 'use_global_for_all is recognized by the store afterwards' do
      # The five-area list lives in the form (write side) AND in the store
      # (read side): this round-trip breaks when the two lists drift apart.
      user.update!(preferences: { 'date_display' => { 'areas' => { 'posts' => 'german' } } })

      form.update(permitted_params('date_display' => { 'use_global_for_all' => '1' }))

      expect(user.preference_store.using_global_date_format_for_all?).to be true
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# With real clicks: the preferences are one page of sections, and a change saves at once
# (user_preferences/edit, preferences_autosave_controller). What a request spec cannot
# see is the browser's half: that a change is sent without a button, that the section
# says so, that a format the page refuses is not sent, and that the page comes back in
# the new language.
RSpec.describe 'The preferences page', type: :system do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  let(:lena) { create(:user, first_name: 'Lena', last_name: 'Beispiel', language_preference: 'de') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: lena, organisation: organisation, role: role, active: true)
    sign_in lena
    visit edit_user_preferences_path
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def saved_text = I18n.t('user_preferences.edit.autosave.saved')
  def failed_text = I18n.t('user_preferences.edit.autosave.failed')

  def section(key)
    find("#section-#{key}")
  end

  def preferences
    lena.reload.preferences
  end

  it 'saves a changed select at once and says so beside its own heading only' do
    within(section('general')) do
      expect(page).to have_no_button(I18n.t('user_preferences.edit.actions.save'))
      select I18n.t('user_preferences.edit.general.items_per_page.options.50'),
             from: I18n.t('user_preferences.edit.general.items_per_page.label')
      expect(page).to have_css('[role="status"][data-state="saved"]', text: saved_text)
    end

    expect(lena.reload.items_per_page_preference).to eq(50)
    expect(section('tickets')).to have_no_css('[role="status"]', text: saved_text)
  end

  it 'saves a chosen radio and a ticket setting, each in its section' do
    within(section('general')) do
      choose I18n.t('user_preferences.edit.display.name_display.initial_last')
      expect(page).to have_css('[role="status"][data-state="saved"]')
    end
    within(section('tickets')) do
      select I18n.t('user_preferences.edit.tickets.timeline_order.reverse'),
             from: I18n.t('user_preferences.edit.tickets.timeline_order.label')
      expect(page).to have_css('[role="status"][data-state="saved"]')
    end

    expect(preferences).to include('name_display' => 'initial_last', 'post_direction' => 'reverse')
  end

  it 'does not send a date format it cannot read, and saves the corrected one' do
    within(section('datetime')) do
      select I18n.t('user_preferences.edit.datetime.formats.custom'),
             from: I18n.t('user_preferences.edit.datetime.global_format.label')
      expect(page).to have_css('[role="status"][data-state="saved"]')

      field = find_field('preferences[date_display][custom_format]')
      field.fill_in with: '%Q'
      field.send_keys(:tab)
      expect(page).to have_css('[role="status"][data-state="failed"]', text: failed_text)
      expect(preferences.dig('date_display', 'custom_format')).not_to eq('%Q')

      field.fill_in with: '%d/%m/%Y'
      field.send_keys(:tab)
      expect(page).to have_css('[role="status"][data-state="saved"]')
    end

    expect(preferences['date_display']).to include('global_format' => 'custom', 'custom_format' => '%d/%m/%Y')
  end

  it 'shows the format per area only while one format for all is switched off' do
    area = I18n.t('user_preferences.datetime.areas.posts')

    within(section('datetime')) do
      expect(page).to have_no_select(area)

      uncheck I18n.t('user_preferences.edit.datetime.use_global.label')
      select I18n.t('user_preferences.edit.datetime.formats.german'), from: area
      expect(page).to have_css('[role="status"][data-state="saved"]')
    end
    expect(preferences.dig('date_display', 'areas', 'posts')).to eq('german')

    within(section('datetime')) do
      check I18n.t('user_preferences.edit.datetime.use_global.label')
      expect(page).to have_no_select(area)
    end
    # "Saved" may still stand there from the save before, so the page cannot say
    # when this one is through: ask the database until it is.
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until preferences.dig('date_display', 'areas', 'posts') == 'inherit'
    end
  end

  it 'goes back to the date defaults after asking, and saves that too' do
    lena.update!(preferences: lena.preferences.merge('date_display' => { 'global_format' => 'german',
                                                                         'areas' => { 'posts' => 'international' } }))
    visit edit_user_preferences_path

    within(section('datetime')) do
      accept_confirm { click_button I18n.t('user_preferences.edit.actions.reset_defaults') }
      expect(page).to have_css('[role="status"][data-state="saved"]')
    end

    expect(preferences['date_display']).to include('global_format' => 'relative')
    expect(preferences.dig('date_display', 'areas', 'posts')).to eq('inherit')
  end

  it 'comes back in the new language after the language changed' do
    expect(page).to have_css('main h1', exact_text: I18n.t('navigation.preferences', locale: :de))

    within(section('language')) { find('label', text: 'English').click }

    expect(page).to have_css('main h1', exact_text: I18n.t('navigation.preferences', locale: :en))
    expect(page).to have_text(I18n.t('user_preferences.language_updated', locale: :en))
    expect(lena.reload.language_preference).to eq('en')
  end

  it 'lands on the section of a former section page' do
    visit '/user_preferences/session'

    expect(page).to have_current_path(edit_user_preferences_path, ignore_query: true)
    expect(page.evaluate_script('window.location.hash')).to eq('#section-session')
    expect(section('session')).to have_select(I18n.t('views.user_preferences.session.label'))
  end
end

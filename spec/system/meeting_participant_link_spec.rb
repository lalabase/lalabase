# frozen_string_literal: true

require 'rails_helper'

# The dialog "Mit Person verknüpfen" beside the participant chips (S2b): only a
# browser shows that it opens in its frame, searches, links, closes on Escape
# and gives the focus back to the button that opened it.
RSpec.describe 'Linking a meeting participant to a person', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:project) { create(:project, organisation: organisation, name: 'Relaunch') }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, title: 'Hosting-Abstimmung') }
  let(:participant) { create(:meeting_participant, meeting: meeting, display_name: 'J. Weber (Hoster)') }
  let(:pl) { 'views.organisations.meetings.participant_links' }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    participant
    create(:person, organisation: organisation, name: 'Jonas Weber', function: 'Hosting')
    create(:person, organisation: organisation, name: 'Anton Anders')
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def trigger_id
    "meeting-participant-link-trigger-#{participant.id}"
  end

  def open_dialog
    find("##{trigger_id}").click
    expect(page).to have_css('[role="dialog"]', text: I18n.t("#{pl}.title"))
    # The search has the focus at once: typing searches without a click first.
    expect(page).to have_css('[role="dialog"] input[type="search"]:focus')
  end

  it 'searches, links, closes and gives the focus back' do
    visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
    open_dialog

    within('[role="dialog"]') do
      expect(page).to have_css('li', text: 'Jonas Weber')
      expect(page).to have_text(I18n.t("#{pl}.suggestion"))
      fill_in I18n.t("#{pl}.search_label"), with: 'anders'
      expect(page).to have_css('li', text: 'Anton Anders')
      expect(page).to have_no_css('li', text: 'Jonas Weber')
      fill_in I18n.t("#{pl}.search_label"), with: 'weber'
      find('label', text: 'Jonas Weber').click
      click_button I18n.t("#{pl}.submit")
    end

    expect(page).to have_no_css('[role="dialog"]')
    expect(page).to have_link(I18n.t("#{pl}.open_person", name: 'J. Weber (Hoster)'))
    expect(participant.reload.person.name).to eq('Jonas Weber')
    expect(page).to have_css("##{trigger_id}:focus")
  end

  # A refusal swaps the dialog for a new instance: the focus must still go back to the
  # button that opened it, and a search in the refused dialog must still work.
  it 'gives the focus back after a refusal, a search and Escape' do
    visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
    open_dialog

    within('[role="dialog"]') { click_button I18n.t("#{pl}.submit") }
    expect(page).to have_css('[role="dialog"]', text: I18n.t('services.actors.link_meeting_participant.nothing_picked'))
    within('[role="dialog"]') do
      fill_in I18n.t("#{pl}.search_label"), with: 'anders'
      expect(page).to have_no_css('li', text: 'Jonas Weber')
    end
    find('[role="dialog"] input[type="search"]').send_keys(:escape)

    expect(page).to have_no_css('[role="dialog"]')
    expect(page).to have_css("##{trigger_id}:focus")

    open_dialog
    expect(page).to have_no_text(I18n.t('services.actors.link_meeting_participant.nothing_picked'))
  end

  it 'closes on Escape without linking' do
    visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
    open_dialog

    find('[role="dialog"] input[type="search"]').send_keys(:escape)

    # The dialog owns that Escape: the meeting behind stays open, and the focus is back on
    # the button that opened the dialog (the title alone also stands in the list row).
    expect(page).to have_no_css('[role="dialog"]')
    # Waits: the controller hands the focus back after the frame is emptied.
    expect(page).to have_css("##{trigger_id}:focus")
    expect(participant.reload.person_id).to be_nil
  end
end

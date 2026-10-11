# frozen_string_literal: true

require 'rails_helper'

# Meetings master-detail — Slice 1a UI.
#
# This repo configures only the rack_test driver for system specs (no JS/Chrome
# driver), so this spec verifies the SERVER-RENDERED surfaces: the warm empty
# state (with CTA) before the first meeting, the list, and the detail pane
# content when a meeting is selected via ?meeting_id=. The JS-driven inline-form
# create flow (Turbo frame + turbo_stream) is exercised end-to-end at the
# request level in spec/requests/organisations/meetings_spec.rb.
RSpec.describe 'Meetings master-detail', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  it 'shows the warm empty state with a CTA before the first meeting' do
    visit organisation_project_meetings_path(organisation, project)

    expect(page).to have_content(I18n.t('views.organisations.meetings.index.empty_first_time_title'))
    expect(page).to have_content(I18n.t('views.organisations.meetings.index.empty_cta'))
  end

  it 'lists a meeting and shows its content in the detail pane when selected' do
    meeting = ActsAsTenant.with_tenant(organisation) do
      create(:meeting, organisation: organisation, project: project, creator: user,
                       title: 'Kickoff mit Kunde',
                       notes: 'Agenda und Ergebnisse',
                       transcript: 'Sprecher A: Hallo')
    end

    visit organisation_project_meetings_path(organisation, project)
    expect(page).to have_content('Kickoff mit Kunde')

    visit organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
    expect(page).to have_content('Kickoff mit Kunde')
    expect(page).to have_content('Agenda und Ergebnisse')
    expect(page).to have_content('Sprecher A: Hallo')
    # The section heading is CSS-uppercased ("TRANSKRIPT"); match case-insensitively.
    expect(page).to have_content(/#{I18n.t('views.organisations.meetings.show.transcript_heading')}/i)
  end
end

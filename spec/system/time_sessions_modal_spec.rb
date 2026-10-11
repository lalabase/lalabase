# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the capture modal on the times index page. A save goes
# through Turbo: a refused one shows its errors inside the still open modal (the
# answer without Turbo was the bare form on an unstyled page, found 28.09.2026),
# a successful one is answered with the list page, so the modal is gone and the
# new booking stands in the list.
#
# CSS is disabled in the default driver, so the hidden class is
# checked instead of Capybara visibility.
RSpec.describe 'Zeiten-Index Erfassen-Modal', type: :system do
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

  let!(:existing_session) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: nil,
                            creator: user, duration: 30,
                            # Pinned: the factory's sequence puts it hours ahead per
                            # booking created before, years ahead late in a full run.
                            occurred_on: Time.current)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  def modal
    page.find('[data-time-sessions-index-target="modal"]', visible: :all)
  end

  it 'schließt das Modal nach erfolgreichem Speichern' do
    visit organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: 'all')

    find('[data-action="click->time-sessions-index#openModal"]', match: :first).click
    expect(modal[:class]).not_to include('hidden')

    within('#time_session_form') do
      fill_in 'time_session[duration_string]', with: '0:30'
      fill_in 'time_session[description]', with: 'Modal-Close-Spec Eintrag'
      find('button[type="submit"]').click
    end

    # Answered with the list page: it counts the new booking, the modal is
    # closed and the page scrolls again.
    expect(page).to have_content(I18n.t('views.organisations.time_sessions.index.result_times', count: 2), wait: 5)
    expect(modal[:class]).to include('hidden')
    expect(page.evaluate_script('document.body.style.overflow')).not_to eq('hidden')
    expect(ActsAsTenant.with_tenant(organisation) { TimeSession.where(description: 'Modal-Close-Spec Eintrag').count }).to eq(1)
  end

  it 'lässt das Modal bei Validierungsfehlern offen' do
    visit organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: 'all')

    find('[data-action="click->time-sessions-index#openModal"]', match: :first).click

    within('#time_session_form') do
      fill_in 'time_session[duration_string]', with: ''
      find('button[type="submit"]').click
    end

    # The errors stand inside the open modal, on the page it was opened on.
    within('[data-time-sessions-index-target="modal"]') do
      expect(page).to have_css('.time-session-error-container', wait: 5)
    end
    expect(modal[:class]).not_to include('hidden')
    expect(page).to have_css('#time_sessions_list_frame')
  end
end

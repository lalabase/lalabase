# frozen_string_literal: true

require 'rails_helper'

# What:  A double click on a link opens what one click opens: the ticket form from the "+" of
#        the list head and from the button of an empty list, and a page from the sidebar.
# Type:  System spec with headless Chrome. Only a browser sends the second request while the
#        first is still running.
# Why:   The second click asks for the same address again. Turbo starts a request for it and
#        cancels the one still running. The duplicate guard of application.js then held the new
#        one back, and Turbo waited for a resume() that nobody calls: the form stayed shut, the
#        page stayed where it was, and the console said nothing (lalabase/lalabase#262).
RSpec.describe 'A double click on a link', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:tickets_path) { organisation_project_tickets_path(organisation, project) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  # Turbo answers a click only once its script runs. Before that a click is a plain visit of
  # the browser, and the sidebar's link would pass with the bug in place. A controller of the
  # body connects after Turbo has started (application.js imports Turbo first).
  def visit_when_ready(path)
    visit path
    wait_for_stimulus('body', 'turbo-cache')
  end

  it 'opens the ticket form from the "+" of the list head' do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, creator: user) }
    visit_when_ready tickets_path
    expect(page).to have_css('#tickets_list_frame tr[data-ticket-id]')

    find('a[href*="/tickets/new"][data-turbo-frame="writing_surface"]', match: :first).double_click

    expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
  end

  it 'opens the ticket form from the button of an empty list' do
    visit_when_ready tickets_path
    within('#tickets_list_frame') do
      find_link(I18n.t('views.organisations.tickets.tickets_results.empty_first_time_cta')).double_click
    end

    expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
  end

  it 'opens a page from the sidebar' do
    visit_when_ready organisation_root_path(organisation)
    expect(page).to have_no_css('#tickets_list_frame')

    find("a[href='#{tickets_path}']", match: :first).double_click

    expect(page).to have_current_path(tickets_path, ignore_query: true, wait: 10)
    expect(page).to have_css('#tickets_list_frame')
  end
end

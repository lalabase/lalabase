# frozen_string_literal: true

require 'rails_helper'

# The "move" dialog of a meeting, clicked for real (doc/meeting_verschieben_plan.md).
# Markup assertions cannot prove what these do: the dialog opening from the lane
# head, Escape closing only the dialog and not the lane behind it, the focus
# returning to the trigger, and a move landing on the meeting in its new project.
RSpec.describe 'Moving a meeting', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:source) { create(:project, organisation: organisation, name: 'Allgemein') }
  let(:target) { create(:project, organisation: organisation, name: 'Relaunch') }
  let(:mm) { 'views.organisations.meetings.move' }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                        active: true)
    target
    sign_in user
  end

  # After the before block above: it needs its tenant.
  let!(:meeting) { create(:meeting, project: source, organisation: organisation, creator: user, title: 'Erstgespräch') }

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def open_dialog
    visit organisation_project_meetings_path(organisation, source, meeting_id: meeting.id)
    find("#meeting-move-trigger-#{meeting.id}").click
    expect(page).to have_css('[role="dialog"]', text: I18n.t("#{mm}.title"))
  end

  it 'closes on Escape without closing the lane, and gives the focus back to the trigger' do
    open_dialog

    # To the focused element: Element#send_keys clicks it first, and a click on
    # the select opens its native list, which takes the Escape.
    page.send_keys(:escape)

    expect(page).to have_no_css('[role="dialog"]')
    expect(page).to have_css("#meeting-move-trigger-#{meeting.id}")
    expect(page.evaluate_script('document.activeElement.id')).to eq("meeting-move-trigger-#{meeting.id}")
  end

  it 'moves the meeting and opens it in its new project' do
    open_dialog

    within('[role="dialog"]') do
      select 'Relaunch', from: I18n.t("#{mm}.target")
      click_button I18n.t("#{mm}.submit")
    end

    expect(page).to have_text(I18n.t('flash.meetings.moved', project: 'Relaunch'))
    expect(page).to have_current_path(organisation_project_meetings_path(organisation, target, meeting_id: meeting.id))
    expect(page).to have_css("#meeting-move-trigger-#{meeting.id}")
    expect(meeting.reload.project).to eq(target)
  end

  it 'says why a meeting with a linked ticket cannot move' do
    ticket = create(:ticket, project: source, organisation: organisation, creator: user)
    Reference.create!(source: meeting, target: ticket, target_title_snapshot: ticket.title)

    open_dialog

    within('[role="dialog"]') do
      expect(page).to have_text(I18n.t("#{mm}.has_ticket_links", count: 1))
      expect(page).to have_no_button(I18n.t("#{mm}.submit"))
      click_button I18n.t("#{mm}.close"), match: :first
    end
    expect(page).to have_no_css('[role="dialog"]')
  end
end

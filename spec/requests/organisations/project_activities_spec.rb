# frozen_string_literal: true

require 'rails_helper'

# The project activity page after S3b (§9a Befund 1, §13-11).
#
# The page had no request spec at all, and it was gated by `view_activities?`,
# which asks "may you read ANY area of this project". A reader with notes access
# therefore saw the whole ticket history. It now shares the assistant's gate, so
# each row is filtered by the area of the event it describes.
RSpec.describe 'Project activities', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation, name: 'Nordlicht Software') }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def permit(**areas)
    create(:project_permission, { user: user, project: project }.merge(areas))
  end

  def ticket_event(title:, actor: user)
    ticket = create(:ticket, project: project, organisation: organisation, title: title)
    create(:activity, trackable: ticket, organisation: organisation, actor: actor,
                      key: 'ticket.created', action: 'created', parameters: { 'display_name' => title })
  end

  def project_event(key:, parameters:)
    create(:activity, trackable: project, organisation: organisation, actor: user,
                      key: key, action: key.split('.').last, parameters: parameters)
  end

  def visit_page(params = {})
    get organisation_project_activities_path(organisation_id: organisation.id, project_id: project.id, **params)
  end

  describe 'the per-area gate' do
    it 'shows a notes reader the note event and NOT the ticket history beside it' do
      permit(notes_access: 'read_only', tickets_access: 'no_access')
      ticket_event(title: 'GEHEIMES TICKET')
      project_event(key: 'project.note_created', parameters: { 'note_title' => 'Protokoll Kickoff' })

      visit_page

      expect(response.body).to include('Protokoll Kickoff')
      expect(response.body).not_to include('GEHEIMES TICKET')
    end

    it 'shows a tickets reader the ticket history and NOT the note event' do
      permit(tickets_access: 'read_only', notes_access: 'no_access')
      ticket_event(title: 'Durchmesser prüfen')
      project_event(key: 'project.note_created', parameters: { 'note_title' => 'GEHEIME NOTIZ' })

      visit_page

      expect(response.body).to include('Durchmesser prüfen')
      expect(response.body).not_to include('GEHEIME NOTIZ')
    end

    # Decided 2026-08-26: project-level events are visible to anybody who sees the
    # project at all, which is what read on ANY area amounts to.
    it 'shows a project rename to a reader of any single area' do
      permit(notes_access: 'read_only')
      project_event(key: 'project.updated', parameters: { 'display_name' => 'Nordlicht Software' })

      visit_page

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Nordlicht Software')
    end
  end

  describe 'the outer door' do
    it 'sends away a member with no area of this project at all' do
      ticket_event(title: 'GEHEIMES TICKET')

      visit_page

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('GEHEIMES TICKET')
    end
  end

  describe 'the activity controls' do
    before { permit(tickets_access: 'read_only', notes_access: 'read_only') }

    it 'applies the personal view without changing the actor filter contract' do
      colleague = create(:user)
      create(:membership, user: colleague, organisation: organisation, active: true)
      ticket_event(title: 'Eigene Änderung')
      ticket_event(title: 'Fremde Änderung', actor: colleague)

      visit_page(view: 'mine')

      expect(response.body).to include('Eigene Änderung')
      expect(response.body).not_to include('Fremde Änderung')
      expect(response.body).to include('aria-current="page"')
    end

    it 'filters by the user-facing knowledge area' do
      ticket_event(title: 'Nicht im Wissen')
      project_event(key: 'project.note_created', parameters: { 'note_title' => 'Wissensfund' })

      visit_page(area: 'knowledge')

      expect(response.body).to include('Wissensfund')
      expect(response.body).not_to include('Nicht im Wissen')
    end

    it 'updates both frames and excludes knowledge rows when filtering to tickets' do
      ticket_event(title: 'Sichtbares Filterticket')
      project_event(key: 'project.document_created', parameters: { 'document_title' => 'AUSSORTIERTES DOKUMENT' })

      get organisation_project_activities_path(organisation_id: organisation.id, project_id: project.id,
                                               area: 'tickets'),
          headers: { 'ACCEPT' => Mime[:turbo_stream].to_s }

      expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
      expect(response.body).to include('<turbo-stream action="update" target="activity-filters">')
      expect(response.body).to include('<turbo-stream action="update" target="activities-list">')
      expect(response.body).to include('Sichtbares Filterticket')
      expect(response.body).not_to include('AUSSORTIERTES DOKUMENT')
    end

    it 'searches ticket numbers and titles from the project activity list' do
      wanted = ticket_event(title: 'Montagefreigabe')
      ticket_event(title: 'Anderer Vorgang')

      visit_page(q: "##{wanted.trackable.number}")

      expect(response.body).to include('Montagefreigabe')
      expect(response.body).not_to include('Anderer Vorgang')
    end
  end

  describe 'the detail lane' do
    before { permit(tickets_access: 'read_only') }

    it 'mounts the shared list/detail lane and wires activity rows to it' do
      activity = ticket_event(title: 'Detail im Seitenlayer')

      visit_page

      page = Nokogiri::HTML(response.body)
      mount = page.at_css('.labor-layout-view')
      row = page.at_css("[data-list-row-id-value='#{activity.id}']")

      expect(mount['data-controller']).to include('layout-toggle', 'index-page')
      expect(page.at_css('turbo-frame#ticket_display_frame')).to be_present
      expect(row['data-controller']).to eq('list-row')
      expect(row['data-list-row-param-value']).to eq('activity_id')
      expect(row['data-list-row-frame-value']).to eq('ticket_display_frame')
    end

    it 'restores a selected activity into the lane after a reload' do
      activity = ticket_event(title: 'Reload-festes Detail')

      visit_page(activity_id: activity.id)

      page = Nokogiri::HTML(response.body)
      frame = page.at_css('turbo-frame#ticket_display_frame')
      selected_row = page.at_css(".selected-row[data-activity-target-id='#{activity.id}']")

      expect(page.at_css('.labor-layout-view')['class']).to include('show-content')
      expect(frame['src']).to include(organisation_project_ticket_path(organisation, project, activity.trackable))
      expect(frame['src']).to include('frame=content', 'frame_id=ticket_display_frame')
      expect(selected_row).to be_present
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What:  The one ticket form (the viewport-filling writing surface) for creating and editing:
#        rendered into turbo-frame#writing_surface, cleared by the save, re-rendered with errors.
# Type:  Request spec (doc/inline_bilder_paket_3_plan.md, P3-1 and P3-3, 2026-08-23).
# Why:   Three forms (index modal, dashboard modal, inline header edit) became one partial.
#        Every caller now goes through tickets#new / tickets#edit with the `modal` frame
#        and gets its answer as Turbo Streams; this spec pins both directions and the
#        field set (title, description, assignees, attributes, tags, attachments, source).
RSpec.describe 'Ticket writing surface', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, creator: user, title: 'Fallbeschreibung', content: '<div>Schritt 1</div>')
  end
  let(:frame_headers) { { 'Turbo-Frame' => 'writing_surface' } }
  let(:stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end
  after { ActsAsTenant.current_tenant = nil }

  def surface
    Nokogiri::HTML.fragment(response.body).at_css('turbo-frame#writing_surface .writing-surface')
  end

  describe 'GET new' do
    it 'renders the surface into the modal frame with every field and the image rule' do
      get new_organisation_project_ticket_path(organisation, project, source: 'index_page'), headers: frame_headers
      expect(response).to have_http_status(:ok)

      expect(surface).to be_present
      expect(surface['data-controller']).to eq('neo-writing-surface')
      expect(surface['data-neo-writing-surface-unsaved-message-value']).to be_present
      form = surface.at_css('form')
      expect(form['action']).to eq(organisation_project_tickets_path(organisation, project))
      %w[ticket[title] ticket[content] ticket[assignee_ids][] ticket[ticket_document_files][] source].each do |name|
        expect(form.at_css(%([name="#{name}"]))).to be_present, name
      end
      expect(form.at_css('lexxy-editor')['data-controller']).to include('neo-rich-text-embeds')
      expect(form.at_css('[name="source"]')['value']).to eq('index_page')
      # The model's bound, so the browser stops typing where the save would refuse.
      expect(form.at_css('[name="ticket[title]"]')['maxlength']).to eq(Ticket::TITLE_MAX_LENGTH.to_s)
    end

    it 'keeps the dashboard as source' do
      get new_organisation_project_ticket_path(organisation, project, source: 'dashboard'), headers: frame_headers
      expect(surface.at_css('[name="source"]')['value']).to eq('dashboard')
    end

    it 'sends a plain (non-frame) request to the ticket list' do
      get new_organisation_project_ticket_path(organisation, project)
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
    end
  end

  describe 'GET edit' do
    it "renders the surface with the ticket's data, its attachments and the update action" do
      get edit_organisation_project_ticket_path(organisation, project, ticket), headers: frame_headers
      expect(response).to have_http_status(:ok)

      form = surface.at_css('form')
      expect(form['action']).to eq(organisation_project_ticket_path(organisation, project, ticket))
      expect(form.at_css('[name="_method"]')['value']).to eq('patch')
      expect(form.at_css('[name="ticket[title]"]')['value']).to eq('Fallbeschreibung')
      expect(form.at_css('lexxy-editor')['value']).to include('Schritt 1')
    end

    it 'sends a plain request to the list with the ticket open' do
      get edit_organisation_project_ticket_path(organisation, project, ticket)
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
    end

    # The delete button used to live in the old edit form; the surface must not lose it.
    it 'offers the delete link (turbo_method, not a nested form) to users allowed to delete' do
      get edit_organisation_project_ticket_path(organisation, project, ticket), headers: frame_headers

      link = surface.at_css('a.writing-surface__delete')
      expect(link['href']).to eq(organisation_project_ticket_path(organisation, project, ticket))
      expect(link['data-turbo-method']).to eq('delete')
      expect(link['data-turbo-confirm'].presence || link['data-neo-button-confirm-value']).to be_present
      expect(surface.css('form').size).to eq(1)
    end

    it 'hides the delete link from users without the delete permission' do
      editor = create(:user)
      create(:membership, user: editor, organisation: organisation, role: create(:role, organisation: organisation, title: 'editor_without_delete'))
      create(:project_permission, user: editor, project: project, tickets_access: 'read_write')
      sign_in editor

      get edit_organisation_project_ticket_path(organisation, project, ticket), headers: frame_headers
      expect(response).to have_http_status(:ok)
      expect(surface.at_css('a.writing-surface__delete')).to be_nil
    end
  end

  describe 'DELETE destroy from the surface' do
    it 'removes the ticket and clears the modal frame' do
      delete organisation_project_ticket_path(organisation, project, ticket), headers: stream_headers

      expect(ActsAsTenant.with_tenant(organisation) { Ticket.exists?(ticket.id) }).to be(false)
      targets = Nokogiri::HTML.fragment(response.body).css('turbo-stream').map { |s| [s['action'], s['target']] }
      expect(targets).to include(%w[update writing_surface])
    end
  end

  describe 'POST create' do
    it 'creates the ticket, clears the modal frame and shows the new ticket' do
      expect do
        post organisation_project_tickets_path(organisation, project),
             params: { source: 'index_page', ticket: { title: 'Neu', content: '<div>x</div>', assignee_ids: [''] } },
             headers: stream_headers
      end.to change { ActsAsTenant.with_tenant(organisation) { Ticket.count } }.by(1)

      expect(response).to have_http_status(:ok)
      streams = Nokogiri::HTML.fragment(response.body).css('turbo-stream')
      expect(streams.map { |s| [s['action'], s['target']] }).to include(%w[update writing_surface], %w[update ticket_display_frame])
      expect(streams.find { |s| s['target'] == 'writing_surface' }.at_css('template').inner_html.strip).to be_empty
    end

    it 're-renders the surface with the errors inside the modal frame' do
      post organisation_project_tickets_path(organisation, project),
           params: { source: 'index_page', ticket: { title: '', content: '' } },
           headers: stream_headers

      stream = Nokogiri::HTML.fragment(response.body).at_css('turbo-stream[target="writing_surface"]')
      expect(stream['action']).to eq('replace')
      expect(stream.at_css('.writing-surface__errors')).to be_present
      expect(stream.at_css('.writing-surface__errors').text).to include(I18n.t('views.organisations.tickets.writing_surface.errors_title'))
    end
  end

  describe 'PATCH update' do
    it 'saves, clears the modal frame and refreshes the display frame' do
      patch organisation_project_ticket_path(organisation, project, ticket),
            params: { ticket: { title: 'Geändert', content: '<div>Schritt 1</div>' } },
            headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.title).to eq('Geändert')
      targets = Nokogiri::HTML.fragment(response.body).css('turbo-stream').map { |s| [s['action'], s['target']] }
      expect(targets).to include(%w[update writing_surface], %w[update ticket_display_frame])
    end

    it 're-renders the surface with the errors when the update is invalid' do
      patch organisation_project_ticket_path(organisation, project, ticket),
            params: { ticket: { title: '' } },
            headers: stream_headers

      stream = Nokogiri::HTML.fragment(response.body).at_css('turbo-stream[target="writing_surface"]')
      expect(stream['action']).to eq('replace')
      expect(stream.at_css('.writing-surface__errors')).to be_present
      expect(ticket.reload.title).to eq('Fallbeschreibung')
    end
  end
end

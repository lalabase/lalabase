# frozen_string_literal: true

require 'rails_helper'

# What: the session's organisation (session[:current_organisation_id]) follows the PAGES a
#       person opens, not every request: a GET or HEAD that asks for HTML, outside a turbo
#       frame, from a controller that serves pages. A frame load, a write, a file, a JSON
#       read under /org/B/ leave it where it was, and still act in B themselves.
# Why:  the lane of the inbox above the organisations talks to the routes of the ticket's
#       organisation (timeline frame, comment, status, files). Before this rule every one of
#       those requests moved the session, so after working in the lane the help page and
#       "Zurück zur Organisation" pointed to the ticket's organisation instead of the one the
#       person was in (doc: cross_org_inbox_s3_plan.md §3.2, §5.1).
#       The rule decides where a back link leads, never a right: every request under /org/
#       takes its organisation from its own address and checks the membership again.
RSpec.describe 'The session organisation follows pages', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation, name: 'Nordwind GmbH') }
  let(:org_b) { create(:organisation, name: 'Suedhang AG') }
  let(:project_a) { ActsAsTenant.with_tenant(org_a) { create(:project, organisation: org_a, name: 'Lager') } }
  let(:project_b) { ActsAsTenant.with_tenant(org_b) { create(:project, organisation: org_b, name: 'Versand') } }
  let(:ticket_b) { ActsAsTenant.with_tenant(org_b) { create(:ticket, project: project_b, title: 'Paket fehlt') } }

  def row_in(org, project, ticket)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: 'in_app', state: :delivered)
    end
  end

  let!(:row_b) do
    Prosopite.pause do
      make_token_owner_a_member(user, org_a, projects: [project_a])
      make_token_owner_a_member(user, org_b, projects: [project_b])
      row_in(org_b, project_b, ticket_b)
    end
  end

  before do
    sign_in user
    # The session in A, set the way a person sets it: by opening a page of A.
    get organisation_notifications_path(org_a, state_filters: %w[unread read])
    expect(response).to have_http_status(:ok)
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  after { ActsAsTenant.current_tenant = nil }

  def inbox_b(**params)
    organisation_notifications_path(org_b, state_filters: %w[unread read], **params)
  end

  def state_of(notification)
    ActsAsTenant.with_tenant(notification.organisation) { Notification.find(notification.id).state }
  end

  it 'moves the session with a page GET under /org/B/' do
    get inbox_b
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Paket fehlt')
    expect(session[:current_organisation_id]).to eq(org_b.id)
  end

  it 'moves the session with a HEAD of a page' do
    head inbox_b
    expect(response).to have_http_status(:ok)
    expect(session[:current_organisation_id]).to eq(org_b.id)
  end

  it 'keeps it for a GET inside a turbo frame, which still shows B' do
    get inbox_b(notification: row_b.id), headers: { 'Turbo-Frame' => 'ticket_pane' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="ticket_pane"').and include('Paket fehlt')
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  it 'keeps it for a GET that asks for JSON, which still answers with B' do
    get inbox_b, headers: { 'Accept' => 'application/json' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('id')).to include(row_b.id)
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  it 'keeps it for a file of B, which is served' do
    document = ActsAsTenant.with_tenant(org_b) { create(:ticket_document, ticket: ticket_b, organisation: org_b) }
    # A file opened in a tab asks like a page.
    get organisation_file_download_path(org_b, kind: 'ticket_document', id: document.id),
        headers: { 'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('test file content')
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  it 'keeps it for a PATCH, which changes the row of B' do
    patch mark_read_organisation_notification_path(org_b, row_b), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:ok)
    expect(state_of(row_b)).to eq('read')
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  it 'keeps it for a POST, which writes a comment into the ticket of B' do
    expect do
      post organisation_project_ticket_posts_path(org_b, project_b, ticket_b),
           params: { post: { content: '<div>Antwort aus der Bahn</div>' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html, text/html', 'Turbo-Frame' => 'ticket_display_frame' }
    end.to change { ActsAsTenant.with_tenant(org_b) { ticket_b.posts.count } }.by(1)
    expect(response).to have_http_status(:ok)
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  it 'keeps it for a DELETE, which removes the row of B' do
    # Without the stream Accept on purpose: the action answers with a redirect.
    delete organisation_notification_path(org_b, row_b)
    expect(response).to have_http_status(:found)
    expect(ActsAsTenant.with_tenant(org_b) { Notification.exists?(row_b.id) }).to be(false)
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  it 'keeps it for a POST that asks for HTML (a form without Turbo), which writes into B' do
    expect do
      post organisation_project_ticket_posts_path(org_b, project_b, ticket_b),
           params: { post: { content: '<div>Ohne Turbo</div>' } },
           headers: { 'Accept' => 'text/html,application/xhtml+xml' }
    end.to change { ActsAsTenant.with_tenant(org_b) { ticket_b.posts.count } }.by(1)
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  # The tenant of a request under /org/B/ comes from its address whatever its kind, and so does
  # the membership it is checked against: a person deactivated in B gets no frame of B, even
  # with the session in A where the membership is active.
  it 'refuses a frame of B to a person deactivated in B, as before' do
    Membership.find_by(user: user, organisation: org_b).update!(active: false)
    get inbox_b(notification: row_b.id), headers: { 'Turbo-Frame' => 'ticket_pane' }
    expect(response).to redirect_to(select_organisation_path)
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end

  # The way back out of the management area asks the same predicate: a frame inside a
  # management page does not overwrite the page the person came from.
  it 'keeps the way back out of the management area through a frame request' do
    inbox_a = organisation_notifications_path(org_a, state_filters: %w[unread read])
    get organisation_settings_path(org_a), headers: { 'Referer' => "http://www.example.com#{inbox_a}" }
    expect(session[:management_return_path]).to eq(inbox_a)

    project_page = organisation_project_tickets_path(org_a, project_a)
    get organisation_settings_path(org_a),
        headers: { 'Referer' => "http://www.example.com#{project_page}", 'Turbo-Frame' => 'settings_frame' }
    expect(session[:management_return_path]).to eq(inbox_a)

    get organisation_settings_path(org_a), headers: { 'Referer' => "http://www.example.com#{project_page}" }
    expect(session[:management_return_path]).to eq(project_page)
  end

  it 'changes nothing for a person who is no member of the organisation in the address' do
    org_c = create(:organisation, name: 'Fremd KG')
    get organisation_notifications_path(org_c, state_filters: %w[unread read])
    expect(session[:current_organisation_id]).to eq(org_a.id)
  end
end

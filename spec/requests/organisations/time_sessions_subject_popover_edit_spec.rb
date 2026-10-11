# frozen_string_literal: true

require 'rails_helper'

# What: Edit mode of the capture popover (user, 05.09.2026). A listed row that
#       was never billed and that the reader may rework is a link carrying
#       ?edit=<id>; the form loads its values (PATCH to the member route), the
#       row says "wird bearbeitet", the creator gets "Löschen". Billed rows are
#       never links and an ?edit= pointing at one falls back to the new-entry
#       form. Saving and deleting answer with the same three popover streams as
#       creating — never with the full ticket_display_frame.
# Type: Request spec against GET subject_popover(edit:), PATCH update, DELETE.
RSpec.describe 'Organisations::TimeSessions subject popover edit', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:colleague)    { create(:user) }

  let(:project) { with_tenant { create(:project, organisation: organisation, name: 'Kesselhaus') } }
  let(:ticket)  { with_tenant { create(:ticket, project: project, creator: admin, title: 'Kessel flicken') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: colleague, organisation: organisation, role: admin_role, active: true)
    end
    Prosopite.pause
    sign_in admin
  end

  # Defined AFTER the membership hook on purpose: let! runs in definition order,
  # and the session factories touch the creator's membership themselves.
  let!(:open_session) do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            ticket: ticket, duration: 20, description: 'Farbreihenfolge geprüft',
                            occurred_on: 1.day.ago)
    end
  end
  let!(:billed_session) do
    with_tenant do
      group = create(:time_session_group, :billed, organisation: organisation, name: '05-2026-muster')
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            ticket: ticket, duration: 28, description: 'Ticket aufgenommen',
                            billed: true, time_session_group: group, occurred_on: 3.days.ago)
    end
  end
  # Assigned to an OPEN billing: not billed yet, but already spoken for. The
  # designer's rule: only open time is editable here; a row in a billing is
  # changed in the billing, and its title says so.
  let!(:grouped_session) do
    with_tenant do
      group = create(:time_session_group, organisation: organisation, name: '06-2026-muster')
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            ticket: ticket, duration: 60, description: 'Vergleich besprochen',
                            time_session_group: group, occurred_on: 2.days.ago)
    end
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def fetch_popover(extra = {})
    get subject_popover_organisation_time_sessions_path(
      organisation, ticket_id: ticket.id, project_id: project.id, **extra
    )
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def stream_targets
    doc.css('turbo-stream').map { |node| [node['action'], node['target']] }
  end

  it 'links only the never-billed row into edit mode' do
    fetch_popover

    edit_links = doc.css('a[href*="edit="]')
    expect(edit_links.size).to eq(1)
    expect(edit_links.first['href']).to include("edit=#{open_session.id}")
    expect(edit_links.first['data-turbo-frame']).to eq("subject_time_popover_#{ticket.id}")
  end

  it 'loads the row into the form: PATCH to the member route, values filled, row marked' do
    fetch_popover(edit: open_session.id)

    form = doc.at_css("form[action='#{organisation_time_session_path(organisation, open_session)}']")
    expect(form).to be_present
    expect(form.at_css("input[name='_method']")&.[]('value')).to eq('patch')
    expect(form.at_css("input[name='time_session[duration_string]']")&.[]('value')).to eq('0:20')
    expect(form.at_css("input[name='time_session[description]']")&.[]('value')).to eq('Farbreihenfolge geprüft')
    expect(response.body).to include(I18n.t('views.organisations.time_sessions.subject_popover.heading_edit'))
    expect(doc.text).to include(I18n.t('views.organisations.time_sessions.subject_popover.editing_row'))
    # The creator sees the delete button (in the row, submitting its own hidden
    # form via the form attribute) with its confirmation.
    delete_button = doc.at_css('button[data-turbo-confirm]')
    expect(delete_button).to be_present
    delete_form = doc.at_css("form##{delete_button['form']}")
    expect(delete_form).to be_present
    expect(delete_form['action']).to eq(organisation_time_session_path(organisation, open_session))
  end

  it 'falls back to the new-entry form when ?edit= points at a billed row' do
    fetch_popover(edit: billed_session.id)

    expect(doc.at_css("form[action='#{organisation_time_sessions_path(organisation)}']")).to be_present
    expect(response.body).not_to include(I18n.t('views.organisations.time_sessions.subject_popover.heading_edit'))
  end

  it 'locks a row in an open billing: no link, a title naming the billing, ?edit= falls back' do
    fetch_popover(edit: grouped_session.id)

    expect(response.body).not_to include(I18n.t('views.organisations.time_sessions.subject_popover.heading_edit'))
    locked = doc.css('span[title]').find { |node| node['title'].include?('06-2026-muster') }
    expect(locked).to be_present
    expect(locked['title'])
      .to eq(I18n.t('views.organisations.time_sessions.subject_popover.locked_row_title', name: '06-2026-muster'))
  end

  # The timeline's time rows trigger the SAME form: one frameless pencil per
  # editable row, opening the popover frame in edit mode. The red trash and the
  # old edit modal are gone from the ticket view.
  describe 'the timeline pencil' do
    it 'links editable rows into the popover frame and drops trash and modal wiring' do
      get timeline_organisation_project_ticket_path(organisation, project, ticket)
      expect(response).to have_http_status(:ok)

      pencil = doc.css("a[href*='edit=#{open_session.id}']").first
      expect(pencil).to be_present
      expect(pencil['data-turbo-frame']).to eq("subject_time_popover_#{ticket.id}")
      expect(pencil['title']).to eq(I18n.t('views.organisations.time_sessions.subject_popover.heading_edit'))

      expect(doc.css("a[href*='edit=#{grouped_session.id}']")).to be_empty
      expect(doc.css("a[href*='edit=#{billed_session.id}']")).to be_empty
      expect(response.body).not_to include('time-session-actions#deleteTimeSession')
      expect(response.body).not_to include('time-session-actions#editTimeSession')
    end
  end

  it 'hides the delete button from an admin who is not the creator, but lets them edit' do
    sign_in colleague
    fetch_popover(edit: open_session.id)

    expect(response.body).to include(I18n.t('views.organisations.time_sessions.subject_popover.heading_edit'))
    expect(doc.at_css('button[data-turbo-confirm]')).to be_nil
  end

  it 'saves and answers with the popover streams, back in new-entry mode' do
    patch organisation_time_session_path(organisation, open_session),
          params: {
            context: 'subject_popover',
            time_session: { duration_string: '0:45', occurred_on: open_session.occurred_on.to_date.to_s,
                            description: 'Farbreihenfolge korrigiert',
                            project_id: project.id, ticket_id: ticket.id }
          },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:ok)
    expect(with_tenant { open_session.reload.duration }).to eq(45)
    expect(stream_targets).to include(['update', "subject_time_popover_#{ticket.id}"],
                                      ['update', "subject_time_chip_value_#{ticket.id}"],
                                      ['replace', "ticket-timeline-#{ticket.id}"])
    expect(response.body).not_to include('ticket_display_frame')
    popover = doc.at_css("turbo-stream[target='subject_time_popover_#{ticket.id}']")
    expect(popover.at_css("form[action='#{organisation_time_sessions_path(organisation)}']")).to be_present
  end

  it 'keeps the edit form open on validation errors' do
    patch organisation_time_session_path(organisation, open_session),
          params: {
            context: 'subject_popover',
            time_session: { duration_string: '0:00', project_id: project.id, ticket_id: ticket.id }
          },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:unprocessable_content)
    expect(with_tenant { open_session.reload.duration }).to eq(20)
    popover = doc.at_css("turbo-stream[target='subject_time_popover_#{ticket.id}']")
    expect(popover).to be_present
    expect(popover.at_css("form[action='#{organisation_time_session_path(organisation, open_session)}']")).to be_present
  end

  it 'deletes as the creator and answers with the popover streams' do
    expect do
      delete organisation_time_session_path(organisation, open_session),
             params: { context: 'subject_popover' },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    end.to change { with_tenant { TimeSession.count } }.by(-1)

    expect(response).to have_http_status(:ok)
    expect(stream_targets).to include(['update', "subject_time_popover_#{ticket.id}"],
                                      ['update', "subject_time_chip_value_#{ticket.id}"])
    expect(response.body).not_to include('ticket_display_frame')
  end

  # The rework rule has a WHO half beside the billing half: creator or account
  # admin. A member who may see and book everything still only reworks their
  # OWN rows — drop the creator/admin clause from
  # subject_popover_row_editable? and the first two examples go red.
  context 'as a member who may view all and book, but is neither creator nor admin' do
    let(:viewer_role) { create(:role, organisation: organisation) }
    let(:viewer)      { create(:user) }

    before do
      with_tenant do
        create(:membership, user: viewer, organisation: organisation, role: viewer_role, active: true)
        create(:project_permission, user: viewer, project: project, tickets_access: 'read_only')
        create(:time_session_permission, user: viewer, project: project,
                                         can_view_own: true, can_view_all: true, can_create_own: true)
      end
      sign_in viewer
    end

    let!(:own_open_session) do
      with_tenant do
        create(:time_session, project: project, organisation: organisation, creator: viewer,
                              ticket: ticket, duration: 15, description: 'Eigene offene Buchung',
                              occurred_on: 2.hours.ago)
      end
    end

    it "links only their OWN open row — the colleague's open time stays view-only" do
      fetch_popover

      edit_links = doc.css('a[href*="edit="]')
      expect(edit_links.size).to eq(1)
      expect(edit_links.first['href']).to include("edit=#{own_open_session.id}")
    end

    it "falls back to the new-entry form when ?edit= points at the colleague's open row" do
      fetch_popover(edit: open_session.id)

      expect(response.body).not_to include(I18n.t('views.organisations.time_sessions.subject_popover.heading_edit'))
      expect(doc.at_css("form[action='#{organisation_time_sessions_path(organisation)}']")).to be_present
    end

    it "cannot delete the colleague's row with a raw request either (server mirrors the button rule)" do
      expect do
        delete organisation_time_session_path(organisation, open_session),
               params: { context: 'subject_popover' },
               headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      end.not_to(change { with_tenant { TimeSession.count } })
    end
  end
end

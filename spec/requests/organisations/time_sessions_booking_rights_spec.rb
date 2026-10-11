# frozen_string_literal: true

require 'rails_helper'

# What: Who may book time from the organisation list, and where. The "record"
#       button and the project select of its form follow the per-project
#       booking right (TimeSessionPermission#can_create_own) the way the list
#       follows the viewing right (doc/zeiten_eine_liste_plan.md, S4). Before
#       this, the button was always there and the form listed every project of
#       the organisation; the right was checked on submit, as an error.
# Type: Request spec over the rendered index.
RSpec.describe 'Organisations::TimeSessions booking rights', type: :request do
  let(:organisation) { create(:organisation) }
  let(:foreign_org)  { create(:organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:user)         { create(:user) }

  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Alpha Bau') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'Beta Bau') } }
  let!(:foreign_project) do
    ActsAsTenant.with_tenant(foreign_org) { create(:project, organisation: foreign_org, name: 'Fremdes Haus') }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: user, organisation: organisation, role: member_role, active: true) }
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def grant(project, **flags)
    with_tenant { create(:time_session_permission, user: user, project: project, **flags) }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def record_button
    doc.css("[title='#{I18n.t('views.organisations.time_sessions.index.record_button')}']")
  end

  # [value, selected?] per option of the form's project select, prompt included.
  def form_project_options
    doc.css('select[name="time_session[project_id]"] option').map { |option| [option['value'], option['selected'].present?] }
  end

  context 'with viewing rights everywhere and booking rights nowhere' do
    before do
      grant(project_a, can_view_all: true, can_create_own: false)
      grant(project_b, can_view_all: true, can_create_own: false)
      sign_in user
    end

    it 'shows no record button' do
      get organisation_time_sessions_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(record_button).to be_empty
    end
  end

  context 'with a booking right in one of two projects' do
    before do
      grant(project_a, can_view_own: true, can_create_own: true)
      grant(project_b, can_view_own: true, can_create_own: false)
      sign_in user
    end

    it 'shows the record button and lists only the bookable project in the form' do
      get organisation_time_sessions_path(organisation)

      expect(record_button).not_to be_empty
      values = form_project_options.map(&:first)
      expect(values).to include(project_a.id)
      expect(values).not_to include(project_b.id)
      expect(values).not_to include(foreign_project.id)
    end

    it 'preselects the project of the active filter when it is bookable' do
      get organisation_time_sessions_path(organisation, project_id_filter: project_a.id)

      selected = form_project_options.find { |_value, chosen| chosen }
      expect(selected&.first).to eq(project_a.id)
    end

    it 'preselects nothing when the filtered project is not bookable' do
      get organisation_time_sessions_path(organisation, project_id_filter: project_b.id)

      expect(form_project_options.none? { |_value, chosen| chosen }).to be true
    end
  end

  context 'as account admin' do
    let(:admin) { create(:user) }

    before do
      with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
      project_a
      project_b
      sign_in admin
    end

    it 'lists every project of the organisation and none of another' do
      get organisation_time_sessions_path(organisation)

      values = form_project_options.map(&:first)
      expect(values).to include(project_a.id, project_b.id)
      expect(values).not_to include(foreign_project.id)
    end

    # The project page used to hand the form a fixed project, tickets already
    # loaded. With the filter as the project, the tickets come with the page
    # instead of after a change event that never fires.
    it 'renders the ticket select of a preselected project with the page' do
      with_tenant { create(:ticket, project: project_a, creator: admin, title: 'Fenster tauschen') }

      get organisation_time_sessions_path(organisation, project_id_filter: project_a.id)

      ticket_select = doc.css('select[name="time_session[ticket_id]"]').first
      expect(ticket_select).to be_present
      expect(ticket_select['disabled']).to be_nil
      expect(ticket_select.css('option').map(&:text)).to include('Fenster tauschen')
    end

    # One select, two ways to fill it: with the page (preselected project) and by
    # the tickets_for_project stream after a change. Both read the same bounded
    # source (selectable_tickets_for: most recently touched first, 200 at most),
    # so the list cannot read one way on load and another after a change
    # (review of PR #675, finding 1).
    it 'fills the ticket select the same way with the page and after a project change' do
      # update_columns: a create callback touches updated_at, so a value handed
      # to the factory would not survive.
      with_tenant do
        { 'Altes Dach' => 3.days.ago, 'Neue Tuer' => 1.day.ago, 'Mittlere Wand' => 2.days.ago }.each do |title, touched|
          create(:ticket, project: project_a, creator: admin, title: title).update_columns(updated_at: touched)
        end
      end

      get organisation_time_sessions_path(organisation, project_id_filter: project_a.id)
      with_page = doc.css('select[name="time_session[ticket_id]"] option').map(&:text)

      get tickets_for_project_organisation_time_sessions_path(organisation, project_id: project_a.id),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      after_change = doc.css('select[name="time_session[ticket_id]"] option').map(&:text)

      expect(with_page).to eq(after_change)
      expect(with_page.last(3)).to eq(['Neue Tuer', 'Mittlere Wand', 'Altes Dach'])
    end
  end
end

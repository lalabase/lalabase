# frozen_string_literal: true

require 'rails_helper'

# The column picker of "Alle Meetings" (meetings_uebersicht_vereinheitlichen_plan.md,
# PR 2): the project page's picker, plus the column "Projekt", which only this
# list offers. The base view of the overview is a view configuration without a
# project, saved through an organisation-level route; a saved view without a
# project keeps its own list, as on the project page.
#
# What the rights examples hold: a reader saves only their own configuration in
# their own organisation, only with read access to meetings somewhere, a view of
# somebody else only with SmartFolderPolicy#update?, and a key the reader may
# not see is refused as a whole (422). Every negative assertion first proves the
# page or the answer it is about.
RSpec.describe 'Organisations::MeetingsOverview columns', :ci_guard, type: :request do
  before { Prosopite.pause } # several requests and setup writes per example
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:overview_path) { organisation_meetings_path(organisation) }
  let(:base_columns_path) { columns_organisation_meetings_view_configuration_path(organisation) }
  let(:json) { { 'ACCEPT' => 'application/json' } }

  def member_with(levels, in_organisation = organisation)
    create(:user).tap do |user|
      ActsAsTenant.with_tenant(in_organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: in_organisation)
        create(:membership, user: user, organisation: in_organisation, role: role, active: true)
        levels.each { |list_project, level| create(:project_permission, user: user, project: list_project, meetings_access: level) }
      end
    end
  end

  let(:reader) { member_with(project => 'read_only') }
  let(:colleague) { member_with(project => 'read_only') }

  def overview_config(user, in_organisation = organisation)
    ActsAsTenant.with_tenant(in_organisation) { ViewConfiguration.find_by(user: user, organisation: in_organisation, project: nil, view_type: 'meetings') }
  end

  def project_config(user)
    ActsAsTenant.with_tenant(organisation) { ViewConfiguration.find_by(user: user, project: project, view_type: 'meetings') }
  end

  def meeting_view(name:, owner:, view_project: nil, columns: %w[title occurred_at])
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, name: name, organisation: organisation, project: view_project, user: owner,
                            target_object_type: 'Meeting', display_columns: { 'table_columns' => columns })
    end
  end

  def columns_of(view)
    ActsAsTenant.with_tenant(organisation) { view.reload.ordered_columns }
  end

  def page_body
    Capybara.string(response.body)
  end

  def head_keys
    page_body.all('#meetings_overview_results thead th').map { |head| head['data-column'] }
  end

  def picker_keys
    # The panel is hidden until its trigger opens it.
    page_body.all('#column-picker li[data-column-key]', visible: :all).map { |row| row['data-column-key'] }
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: reader, title: 'Alpha Kickoff').tap do |meeting|
        create(:meeting_participant, meeting: meeting, display_name: 'Anna Müller')
      end
    end
  end

  describe 'the page' do
    before { sign_in reader }

    it 'shows on a first visit the columns it always showed, with the picker at the bar' do
      get overview_path

      expect(response).to have_http_status(:ok)
      expect(head_keys).to eq(%w[title project occurred_at duration_minutes participants])
      expect(page_body).to have_css('[data-controller="filter-bar"] [data-column-picker-trigger]')
      expect(page_body).to have_css('[data-controller~="column-picker"]')
      expect(page_body.find('[data-controller~="column-picker"]')['data-column-picker-save-url-value']).to eq(base_columns_path)
      expect(picker_keys).to include('title', 'project', 'creator', 'created_at')
      expect(overview_config(reader)).to be_nil
    end

    it 'offers the column "Projekt" only here, not on the project page' do
      get organisation_project_meetings_path(organisation, project)
      expect(response).to have_http_status(:ok)
      expect(picker_keys).to include('title', 'occurred_at')
      expect(picker_keys).not_to include('project')

      get overview_path
      expect(picker_keys).to include('project')
    end

    it 'renders the stored list with ranks and minimum widths, and the pinned values under the title' do
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.for_user_organisation(reader, organisation, 'meetings').tap do |config|
          config.ordered_columns = %w[title participants project]
          config.pinned_column_keys = %w[project]
          config.save!
        end
      end

      get overview_path

      expect(head_keys).to eq(%w[title participants project])
      ranked = page_body.all('#meetings_overview_results thead th[data-rank]').map { |head| [head['data-column'], head['data-rank'], head['data-col-min']] }
      expect(ranked).to eq([%w[participants 1 220], %w[project 2 140]])
      meta = page_body.all('#meetings_overview_results tbody tr[data-meeting-id] .ticket-meta__item', visible: :all)
      shown_under_title = meta.to_h { |item| [item.text.strip, item[:hidden].nil?] }
      expect(shown_under_title).to eq('Anna Müller' => false, 'Projekt Alpha' => true)
    end
  end

  describe 'saving the base view' do
    it 'stores the list and the pins in a row of its own, apart from the project page' do
      sign_in reader
      patch base_columns_path, params: { cols: %w[project title creator], pins: %w[creator] }, headers: json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('success' => true, 'columns' => %w[title project creator])
      expect(overview_config(reader).ordered_columns).to eq(%w[title project creator])
      expect(overview_config(reader).pinned_column_keys).to eq(%w[creator])
      expect(project_config(reader)).to be_nil

      get overview_path
      expect(head_keys).to eq(%w[title project creator])
    end

    it 'refuses an unknown key with 422 and stores nothing' do
      sign_in reader
      patch base_columns_path, params: { cols: %w[title nope] }, headers: json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['success']).to be false
      expect(overview_config(reader)).to be_nil
    end

    it 'refuses the column "Projekt" on the project page with 422' do
      sign_in reader
      patch columns_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings'),
            params: { cols: %w[title occurred_at] }, headers: json
      expect(response).to have_http_status(:ok)

      patch columns_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings'),
            params: { cols: %w[title project] }, headers: json
      expect(response).to have_http_status(:unprocessable_content)
      expect(project_config(reader).ordered_columns).to eq(%w[title occurred_at])
    end

    it 'cannot be turned into a ticket view without a project' do
      sign_in reader
      patch base_columns_path, params: { cols: %w[title], view_type: 'tickets' }, headers: json

      expect(response).to have_http_status(:ok)
      expect(overview_config(reader).view_type).to eq('meetings')
      expect(ActsAsTenant.with_tenant(organisation) { ViewConfiguration.where(user: reader, project: nil).pluck(:view_type) }).to eq(%w[meetings])
    end

    it 'refuses a reader without read access to meetings anywhere and stores nothing' do
      without_meetings = member_with(project => 'no_access')
      sign_in without_meetings

      patch base_columns_path, params: { cols: %w[title project] }, headers: json

      expect(response).to have_http_status(:forbidden)
      expect(overview_config(without_meetings)).to be_nil
    end

    it 'writes only the own row and never reads the row of a colleague' do
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.for_user_organisation(colleague, organisation, 'meetings').tap do |config|
          config.ordered_columns = %w[title creator]
          config.save!
        end
      end
      sign_in reader

      get overview_path
      expect(head_keys).to eq(%w[title project occurred_at duration_minutes participants])

      patch base_columns_path, params: { cols: %w[title updated_at] }, headers: json
      expect(response).to have_http_status(:ok)
      expect(overview_config(reader).ordered_columns).to eq(%w[title updated_at])
      expect(overview_config(colleague).ordered_columns).to eq(%w[title creator])
    end

    it 'does not reach into another organisation' do
      foreign_project = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
      member_with({ foreign_project => 'read_only' }, other_organisation)
      sign_in reader

      patch columns_organisation_meetings_view_configuration_path(other_organisation), params: { cols: %w[title] }, headers: json

      expect(response).to have_http_status(:found)
      expect(overview_config(reader, other_organisation)).to be_nil
      expect(overview_config(reader)).to be_nil

      patch columns_organisation_meetings_view_configuration_path(organisation), params: { cols: %w[title] }, headers: json
      expect(response).to have_http_status(:ok)
      expect(overview_config(reader).ordered_columns).to eq(%w[title])
    end
  end

  describe 'a saved view without a project' do
    let(:own_view) { meeting_view(name: 'Meine', owner: reader) }

    it 'stores its own list, the column "Projekt" included, and leaves the base view alone' do
      sign_in reader
      patch columns_organisation_smart_folder_path(organisation, own_view), params: { cols: %w[project title], pins: %w[project] }, headers: json

      expect(response).to have_http_status(:ok)
      expect(columns_of(own_view)).to eq(%w[title project])
      expect(ActsAsTenant.with_tenant(organisation) { own_view.reload.pinned_column_keys }).to eq(%w[project])
      expect(overview_config(reader)).to be_nil

      get overview_path, params: { smart_folder_id: own_view.id }
      expect(head_keys).to eq(%w[title project])
    end

    it 'ignores a project id from the request: the view belongs to the overview' do
      sign_in reader
      patch columns_organisation_smart_folder_path(organisation, own_view), params: { cols: %w[title project], project_id: project.id }, headers: json

      expect(response).to have_http_status(:ok)
      expect(columns_of(own_view)).to eq(%w[title project])
    end

    it 'refuses an unknown key with 422' do
      sign_in reader
      patch columns_organisation_smart_folder_path(organisation, own_view), params: { cols: %w[title nope] }, headers: json

      expect(response).to have_http_status(:unprocessable_content)
      expect(columns_of(own_view)).to eq(%w[title occurred_at])
    end

    it 'takes no list from somebody who may not change it' do
      sign_in colleague
      ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: own_view, user: colleague, can_edit: false) }

      get overview_path, params: { smart_folder_id: own_view.id }
      expect(response).to have_http_status(:ok)
      expect(head_keys).to eq(%w[title occurred_at])

      patch columns_organisation_smart_folder_path(organisation, own_view), params: { cols: %w[title project] }, headers: json
      expect(response).to have_http_status(:found)
      expect(columns_of(own_view)).to eq(%w[title occurred_at])
    end

    it 'starts with the columns and pins of the base view of the overview' do
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.for_user_organisation(reader, organisation, 'meetings').tap do |config|
          config.ordered_columns = %w[title project creator]
          config.pinned_column_keys = %w[creator]
          config.save!
        end
      end
      sign_in reader

      post create_from_filters_organisation_smart_folders_path(organisation, target_object_type: 'Meeting', return_to: 'meetings'),
           params: { smart_folder_name: 'Mit Anna', filter: { participant: ['anna müller'] } }

      saved = ActsAsTenant.with_tenant(organisation) { SmartFolder.find_by!(name: 'Mit Anna') }
      expect(saved.project_id).to be_nil
      expect(saved.ordered_columns).to eq(%w[title project creator])
      expect(saved.pinned_column_keys).to eq(%w[creator])
    end

    it 'starts with the overview defaults when the base view was never saved' do
      sign_in reader

      post create_from_filters_organisation_smart_folders_path(organisation, target_object_type: 'Meeting', return_to: 'meetings'),
           params: { smart_folder_name: 'Mit Anna', filter: { participant: ['anna müller'] } }

      saved = ActsAsTenant.with_tenant(organisation) { SmartFolder.find_by!(name: 'Mit Anna') }
      expect(saved.ordered_columns).to eq(%w[title project occurred_at duration_minutes participants])
      expect(saved.pinned_column_keys).to eq(%w[project participants])
    end
  end

  describe '"für alle Ansichten übernehmen" on the overview' do
    let(:apply_path) { apply_columns_to_all_organisation_meetings_view_configuration_path(organisation) }

    it 'writes the base view of the overview and the own meeting views without a project, nothing else' do
      own_overview_view = meeting_view(name: 'Übersicht', owner: reader)
      own_project_view = meeting_view(name: 'Projekt', owner: reader, view_project: project)
      colleagues_view = meeting_view(name: 'Kollegin', owner: colleague)
      own_ticket_view = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, name: 'Tickets', organisation: organisation, project: nil, user: reader,
                              target_object_type: 'Ticket', display_columns: { 'table_columns' => %w[number title] })
      end
      sign_in reader

      patch apply_path, params: { view_configuration: { table_columns: %w[project creator nope] } }

      expect(response).to redirect_to(overview_path)
      expect(flash[:notice]).to eq('Spalten für 2 Ansichten übernommen.')
      expect(overview_config(reader).ordered_columns).to eq(%w[title project creator])
      expect(columns_of(own_overview_view)).to eq(%w[title project creator])
      expect(columns_of(own_project_view)).to eq(%w[title occurred_at])
      expect(columns_of(colleagues_view)).to eq(%w[title occurred_at])
      expect(ActsAsTenant.with_tenant(organisation) { own_ticket_view.reload.ordered_columns }).to eq(%w[number title])
      expect(project_config(reader)).to be_nil
    end

    it 'refuses a reader without read access to meetings anywhere' do
      without_meetings = member_with(project => 'no_access')
      own_view = meeting_view(name: 'Übersicht', owner: without_meetings)
      sign_in without_meetings

      patch apply_path, params: { view_configuration: { table_columns: %w[project] } }

      expect(response).to have_http_status(:forbidden)
      expect(columns_of(own_view)).to eq(%w[title occurred_at])
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Saved views on "Alle Meetings" (doc/meetings_uebersicht_vereinheitlichen_plan.md,
# PR 1, decision 3). A meeting view without a project belongs to the overview and
# shows only there; a meeting view with a project shows only on that project's
# page. The shared parts (filter bar, save, rename, share, duplicate, delete,
# expert filter) take `project: nil` as "organisation-wide".
RSpec.describe 'Organisations::MeetingsOverview saved views', :ci_guard, type: :request do
  before { Prosopite.pause } # several requests per example
  after { Prosopite.resume }

  %i[get post patch delete].each do |verb|
    define_method(verb) do |*args, **options|
      super(*args, **options).tap { ActsAsTenant.current_tenant = organisation }
    end
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project_a) { create(:project, organisation: organisation, name: 'Projekt Alpha') }
  let(:project_b) { create(:project, organisation: organisation, name: 'Projekt Beta') }
  let(:project_hidden) { create(:project, organisation: organisation, name: 'Projekt Geheim') }
  let(:overview_path) { organisation_meetings_path(organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, organisation: organisation, user: user, role: create(:role, organisation: organisation), active: true)
    create(:project_permission, project: project_a, user: user, meetings_access: 'read_write')
    create(:project_permission, project: project_b, user: user, meetings_access: 'read_only')
    project_hidden
    sign_in user
  end
  after { ActsAsTenant.current_tenant = nil }

  def record(title, project:, names: [])
    create(:meeting, project: project, organisation: organisation, creator: user, title: title).tap do |meeting|
      names.each { |name| create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: name) }
    end
  end

  def folder(name, project: nil, owner: user, **attributes)
    create(:smart_folder, name: name, user: owner, organisation: organisation, project: project,
                          target_object_type: 'Meeting', **attributes)
  end

  def page_at(path, **params)
    get path, params: params
    expect(response).to have_http_status(:ok)
    Capybara.string(response.body)
  end

  def tabs(page)
    page.all('[role="tab"]').map { |tab| tab.text.strip }
  end

  def overview_titles(page)
    page.all('#meetings_overview_results tr[data-meeting-id] h5').map { |title| title.text.strip }
  end

  def save_from_filters(**params)
    post create_from_filters_organisation_smart_folders_path(organisation, target_object_type: 'Meeting', return_to: 'meetings'),
         params: params
  end

  describe 'saving a new view on the overview' do
    it 'stores it without a project and opens it on the overview with the list state' do
      record('Alpha Kickoff', project: project_a)
      record('Beta Retro', project: project_b)

      expect do
        save_from_filters(smart_folder_name: 'Nur Alpha', filter: { project: [project_a.id] },
                          list_context: { search: 'Kick', search_mode: 'title_only' })
      end.to change(SmartFolder, :count).by(1)

      saved = SmartFolder.find_by!(name: 'Nur Alpha')
      expect(saved.project_id).to be_nil
      expect(saved.organisation_id).to eq(organisation.id)
      expect(response).to redirect_to(organisation_meetings_path(organisation, search: 'Kick', search_mode: 'title_only', smart_folder_id: saved.id))

      page = page_at(overview_path, smart_folder_id: saved.id)
      expect(overview_titles(page)).to eq(['Alpha Kickoff'])
      expect(page.find('[data-controller="filter-bar"]')['data-filter-bar-smart-folder-id-value']).to eq(saved.id)
      expect(JSON.parse(page.find('[data-controller="filter-bar"]')['data-filter-bar-dissolver-value']))
        .to include('dissolvable' => true, 'filters' => { 'project' => [project_a.id] })
    end

    it 'reads back "not" and several projects the way it was saved' do
      save_from_filters(smart_folder_name: 'Ohne Alpha', filter: { project: [project_a.id] }, filter_op: { project: 'not' })
      not_alpha = SmartFolder.find_by!(name: 'Ohne Alpha')
      save_from_filters(smart_folder_name: 'Beide', filter: { project: [project_a.id, project_b.id] })
      both = SmartFolder.find_by!(name: 'Beide')

      expect(SmartFolderDissolver.new(not_alpha, user).call)
        .to have_attributes(dissolvable?: true, ad_hoc_filters: { 'project' => [project_a.id] }, ad_hoc_operators: { 'project' => 'not' })
      expect(SmartFolderDissolver.new(both, user).call)
        .to have_attributes(dissolvable?: true, ad_hoc_filters: { 'project' => [project_a.id, project_b.id] })

      record('Alpha Kickoff', project: project_a)
      record('Beta Retro', project: project_b)
      expect(overview_titles(page_at(overview_path, smart_folder_id: not_alpha.id))).to eq(['Beta Retro'])
      expect(overview_titles(page_at(overview_path, smart_folder_id: both.id))).to contain_exactly('Alpha Kickoff', 'Beta Retro')
    end

    it 'refuses a project the reader cannot read, without a folder' do
      expect { save_from_filters(smart_folder_name: 'Geheim', filter: { project: [project_hidden.id] }) }
        .not_to change(SmartFolder, :count)
      expect(response).to redirect_to(overview_path)
    end
  end

  describe 'which list shows which view' do
    let!(:overview_view) { folder('Übersichtsansicht') }
    let!(:project_view) { folder('Projektansicht', project: project_a) }

    it 'shows a view without a project only on the overview' do
      record('Alpha Kickoff', project: project_a)

      expect(tabs(page_at(overview_path))).to include('Übersichtsansicht')
      expect(tabs(page_at(overview_path))).not_to include('Projektansicht')

      project_page = page_at(organisation_project_meetings_path(organisation, project_a))
      expect(tabs(project_page)).to include('Projektansicht')
      expect(tabs(project_page)).not_to include('Übersichtsansicht')
    end

    it 'opens neither view on the other list by address' do
      record('Alpha Kickoff', project: project_a)

      on_overview = page_at(overview_path, smart_folder_id: project_view.id)
      expect(on_overview.find('[data-controller="filter-bar"]')['data-filter-bar-smart-folder-id-value']).to be_blank

      on_project = page_at(organisation_project_meetings_path(organisation, project_a), smart_folder_id: overview_view.id)
      expect(on_project.find('[data-controller="filter-bar"]')['data-filter-bar-smart-folder-id-value']).to be_blank
    end
  end

  describe 'changing, renaming, duplicating, sharing and deleting' do
    # The bar stands only once there is a meeting to filter.
    before { record('Alpha Kickoff', project: project_a) }

    let!(:saved) do
      folder('Alpha').tap do |view|
        view.smart_folder_rule_groups.create!(position: 1)
            .smart_folder_rules.create!(field: 'project', operator: 'equals', value: project_a.id, position: 1)
      end
    end

    it 'saves changed conditions into the view without a project' do
      patch update_from_filters_organisation_smart_folder_path(organisation, saved),
            params: { filter: { project: [project_b.id] } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(SmartFolderDissolver.new(saved.reload, user).call.ad_hoc_filters).to eq('project' => [project_b.id])
      expect(saved.project_id).to be_nil
    end

    it 'refuses a change to a project the reader cannot read' do
      patch update_from_filters_organisation_smart_folder_path(organisation, saved),
            params: { filter: { project: [project_hidden.id] } }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(SmartFolderDissolver.new(saved.reload, user).call.ad_hoc_filters).to eq('project' => [project_a.id])
    end

    it 'renames, duplicates and deletes it, and deleting returns to the overview' do
      patch rename_organisation_smart_folder_path(organisation, saved), params: { name: 'Alpha neu' }, as: :json
      expect(response.parsed_body).to include('success' => true, 'name' => 'Alpha neu')

      post clone_organisation_smart_folder_path(organisation, saved), params: { new_folder_name: 'Alpha Kopie' }, as: :json
      copy = SmartFolder.find(response.parsed_body.fetch('id'))
      expect(copy.project_id).to be_nil
      expect(tabs(page_at(overview_path))).to include('Alpha neu', 'Alpha Kopie')

      delete organisation_smart_folder_path(organisation, saved, return_to: 'meetings')
      expect(response).to redirect_to(overview_path)
      expect(SmartFolder.exists?(saved.id)).to be(false)
    end

    it 'offers the menu entries of the active view' do
      page = page_at(overview_path, smart_folder_id: saved.id)
      menu = page.find('[data-filter-bar-target="viewMenu"]', visible: :all)

      expect(menu).to have_link(I18n.t('components.filter_bar.share'), visible: :all)
      expect(menu).to have_button(I18n.t('components.filter_bar.duplicate_view'), visible: :all)
      expert = menu.find_link(I18n.t('components.filter_bar.open_expert_filter'), visible: :all)[:href]
      expect(expert).to include("/smart_folders/#{saved.id}/edit")
      expect(expert).not_to include('project_id')

      get share_organisation_smart_folder_path(organisation, saved)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'the expert filter from the overview' do
    it 'starts a view without a project and returns to the overview' do
      get new_organisation_smart_folder_path(organisation, context_type: 'Meeting', modal: true, return_to: 'meetings')
      expect(response).to have_http_status(:ok)
      expect(Capybara.string(response.body)).to have_css('select option[value="project"]', visible: :all)

      post organisation_smart_folders_path(organisation),
           params: { return_to: 'meetings',
                     smart_folder: { name: 'Experte', target_object_type: 'Meeting',
                                     smart_folder_rule_groups_attributes: { '0' => { position: 1, smart_folder_rules_attributes: {
                                       '0' => { field: 'project', operator: 'equals', value: project_a.id, position: 1 }
                                     } } } } }
      saved = SmartFolder.find_by!(name: 'Experte')
      expect(saved.project_id).to be_nil
      expect(response).to redirect_to(organisation_meetings_path(organisation, smart_folder_id: saved.id))
    end

    it 'offers only readable projects as values of the project field' do
      get organisation_reference_options_path(organisation, field: 'project'), params: { context_type: 'Meeting' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('options').map { |option| option['label'] }).to eq(['Projekt Alpha', 'Projekt Beta'])
    end

    it 'does not offer the project field on a view of one project' do
      get new_organisation_smart_folder_path(organisation, context_type: 'Meeting', project_id: project_a.id, modal: true, return_to: 'meetings')

      expect(response).to have_http_status(:ok)
      form = Capybara.string(response.body)
      expect(form).to have_css('select option[value="participant"]', visible: :all)
      expect(form).not_to have_css('select option[value="project"]', visible: :all)
    end
  end
end

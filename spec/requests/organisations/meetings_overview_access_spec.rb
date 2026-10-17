# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" with the shared filter bar: what the page may reveal. The list,
# every filter category's options and every chip label come from the meetings
# this reader may read (policy_scope(Meeting), area :meetings). A filter only
# narrows; an id from the address names nothing the reader could not see anyway.
#
# Every negative assertion first proves the page rendered with the thing it is
# about (the bar, the row), so a 404 or a redirect cannot pass it in a vacuum.
RSpec.describe 'Organisations::MeetingsOverview access', :ci_guard, type: :request do
  before { Prosopite.pause } # several requests and setup writes per example
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') } }
  let(:overview_path) { organisation_meetings_path(organisation) }

  def member_with(levels)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      levels.each { |project, level| create(:project_permission, user: user, project: project, meetings_access: level) }
    end
    user
  end

  let(:reader_a) { member_with(project_a => 'read_only') }
  let(:other_user) { create(:user, first_name: 'Bertha', last_name: 'Beta') }

  def create_meeting(project:, title:, creator:, participants: [])
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: creator, title: title).tap do |meeting|
        participants.each { |name| create(:meeting_participant, meeting: meeting, display_name: name) }
      end
    end
  end

  def page_body
    Capybara.string(response.body)
  end

  def bar_categories
    JSON.parse(page_body.find('[data-controller="filter-bar"]')['data-filter-bar-categories-value'])
  end

  def category_options(key)
    bar_categories.find { |category| category['key'] == key }&.fetch('options') || []
  end

  def row_titles
    page_body.all('#meetings_overview_results tr[data-meeting-id] h5').map { |title| title.text.strip }
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: other_user, organisation: organisation,
                          role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: true)
    end
    create_meeting(project: project_a, title: 'Alpha Kickoff', creator: reader_a, participants: ['Anna Müller'])
    create_meeting(project: project_b, title: 'Beta Retro', creator: other_user, participants: ['Bert Berg'])
  end

  describe 'filter options' do
    it 'offers project, participant and creator options only from readable meetings' do
      sign_in reader_a
      get overview_path

      expect(response).to have_http_status(:ok)
      expect(category_options('project').map { |option| option['label'] }).to eq(['Projekt Alpha'])
      expect(category_options('participant').map { |option| option['label'] }).to eq(['Anna Müller'])
      expect(category_options('creator').map { |option| option['value'] }).to eq([reader_a.id])
      expect(response.body).not_to include('Projekt Beta', 'Bert Berg', 'Bertha')
    end
  end

  describe 'a forged project filter' do
    it 'matches nothing and names nothing, not even in the chip' do
      sign_in reader_a
      get overview_path, params: { filter: { project: [project_b.id] } }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('[data-controller="filter-bar"]')
      expect(row_titles).to be_empty
      expect(response.body).not_to include('Beta Retro', 'Projekt Beta')
    end

    it 'cannot be saved as a view either' do
      sign_in reader_a

      expect do
        post create_from_filters_organisation_smart_folders_path(organisation, target_object_type: 'Meeting', return_to: 'meetings'),
             params: { smart_folder_name: 'Forged', filter: { project: [project_b.id] } }
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { SmartFolder.count } })

      expect(response).to redirect_to(organisation_meetings_path(organisation))
    end
  end

  describe 'the expert filter of a view with a project condition' do
    it 'offers only readable projects in the server-rendered value list' do
      view = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, name: 'Nur Alpha', user: reader_a, organisation: organisation, project: nil,
                              target_object_type: 'Meeting').tap do |folder|
          folder.smart_folder_rule_groups.create!(position: 1)
                .smart_folder_rules.create!(field: 'project', operator: 'equals', value: project_a.id, position: 1)
        end
      end
      sign_in reader_a
      get edit_organisation_smart_folder_path(organisation, view, modal: true, return_to: 'meetings')

      expect(response).to have_http_status(:ok)
      value_select = Capybara.string(response.body).find("select[data-field='project']")
      expect(value_select.all('option').map(&:text)).to include('Projekt Alpha')
      expect(response.body).not_to include('Projekt Beta', project_b.id)
    end
  end

  describe 'saved views of somebody else' do
    it 'does not open a private overview view of another user' do
      foreign = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, name: 'Fremde Ansicht', user: other_user, organisation: organisation,
                              project: nil, target_object_type: 'Meeting')
      end
      sign_in reader_a
      get overview_path, params: { smart_folder_id: foreign.id }

      expect(response).to have_http_status(:ok)
      expect(row_titles).to eq(['Alpha Kickoff'])
      expect(page_body).not_to have_css('[role="tab"]', text: 'Fremde Ansicht')
      expect(page_body.find('[data-controller="filter-bar"]')['data-filter-bar-smart-folder-id-value']).to be_blank
    end
  end

  describe 'another organisation' do
    it 'shows nothing of it, not by address and not as an option' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        foreign_project = create(:project, organisation: other_org, name: 'Fremd Projekt')
        create(:meeting, project: foreign_project, organisation: other_org, creator: create(:user), title: 'Fremd Meeting')
        @foreign_project_id = foreign_project.id
      end
      sign_in reader_a

      get overview_path
      expect(row_titles).to eq(['Alpha Kickoff'])
      expect(response.body).not_to include('Fremd Meeting', 'Fremd Projekt')

      get overview_path, params: { filter: { project: [@foreign_project_id] } }
      expect(page_body).to have_css('[data-controller="filter-bar"]')
      expect(row_titles).to be_empty
      expect(response.body).not_to include('Fremd Projekt')
    end
  end

  describe 'a reader without meetings access anywhere' do
    it 'is sent away before the page renders' do
      sign_in member_with({})
      get overview_path

      expect(response).to have_http_status(:redirect)
    end
  end
end

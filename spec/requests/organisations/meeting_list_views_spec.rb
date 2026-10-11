# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Project meeting views', type: :request do
  before { Prosopite.pause } # These scenarios intentionally make several requests.
  after { Prosopite.resume }

  %i[get post patch delete].each do |verb|
    define_method(verb) do |*args, **options|
      super(*args, **options).tap { ActsAsTenant.current_tenant = organisation }
    end
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, organisation: organisation, user: user, role: create(:role, organisation: organisation), active: true)
    create(:project_permission, project: project, user: user, meetings_access: 'read_write')
    sign_in user
  end
  after { ActsAsTenant.current_tenant = nil }

  def list(**state)
    get organisation_project_meetings_path(organisation, project), params: state
    expect(response).to have_http_status(:ok)
    Capybara.string(response.body)
  end

  def record(title, names: [], **attributes)
    create(:meeting, project: project, organisation: organisation, creator: user, title: title, **attributes).tap do |meeting|
      names.each { |name| create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: name) }
    end
  end

  def folder(name: 'Ansicht', owner: user, **attributes)
    create(:smart_folder, name: name, user: owner, organisation: organisation, project: project,
                          target_object_type: 'Meeting', **attributes)
  end

  def ids(page)
    page.all('#meetings_results tr[data-meeting-id]').map { |row| row['data-meeting-id'] }
  end

  it 'paginates stable results, counts all hits and clamps the last page' do
    meetings = 3.times.map { |n| record("Meeting #{n}") }
    page = list(items: 2, sort: { column: 'title', direction: 'asc' })
    expect(ids(page)).to eq(meetings.first(2).map(&:id))
    expect(page.find('[data-fb-hits-total]')['data-fb-hits-total']).to eq('3')
    expect(ids(list(items: 2, page: 99, sort: { column: 'title', direction: 'asc' }))).to eq([meetings.last.id])
  end

  it 'saves and edits multi-participant views, drops conditions and keeps the search mode' do
    both = record('Both', names: %w[Anna Bert])
    anna = record('Anna', names: %w[Anna])
    record('Other', names: %w[Clara])
    post create_from_filters_organisation_smart_folders_path(organisation), params: {
      project_id: project.id, return_to: 'meetings', target_object_type: 'Meeting', smart_folder_name: 'Team',
      filter: { participant: %w[Anna Bert] }, filter_op: { participant: 'and' }
    }
    saved = SmartFolder.find_by!(name: 'Team')
    expect(response).to redirect_to(organisation_project_meetings_path(organisation, project, smart_folder_id: saved.id))
    expect(saved.ordered_columns).to eq(%w[title occurred_at duration_minutes participants])
    expect(saved.pinned_column_keys).to eq(%w[participants])
    expect(ids(list(smart_folder_id: saved.id))).to eq([both.id])
    expect(ids(list(smart_folder_id: saved.id, filter: { participant: %w[Anna Bert] }))).to contain_exactly(both.id, anna.id)
    expect(ids(list(smart_folder_id: saved.id, filter_drop: ['participant']))).to have_attributes(size: 3)
    patch update_from_filters_organisation_smart_folder_path(organisation, saved), params: { filter: { participant: ['Anna'] } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(ids(list(smart_folder_id: saved.id, search: 'Anna', search_mode: 'title_only'))).to eq([anna.id])
    patch update_from_filters_organisation_smart_folder_path(organisation, saved), params: { filter: {}, clear_filters: '1' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(ids(list(smart_folder_id: saved.id))).to have_attributes(size: 3)
  end

  it 'ignores foreign-project, unreadable, and wrong-type views and hides foreign participant names' do
    local = record('Local')
    foreign = create(:meeting, project: other_project, organisation: organisation, creator: user, title: 'Secret')
    create(:meeting_participant, meeting: foreign, organisation: organisation, display_name: 'Secret Person')
    stranger = create(:user)
    foreign_folder = folder(project: other_project, name: 'Foreign view')
    private_folder = folder(owner: stranger, name: 'Private view')
    ticket_folder = folder(target_object_type: 'Ticket', name: 'Ticket view')
    [foreign_folder, private_folder, ticket_folder].each do |saved|
      page = list(smart_folder_id: saved.id)
      expect(ids(page)).to eq([local.id])
      expect(page).not_to have_text(saved.name)
      expect(response.body).not_to include('Secret Person')
    end
  end

  it 'separates base, saved-view, project and ticket columns and rejects unknown columns' do
    saved = folder
    columns_path = columns_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings')
    patch columns_path, params: { cols: %w[participants creator], pins: %w[creator] }, as: :json
    expect(response).to have_http_status(:ok)
    base = ViewConfiguration.find_by!(user: user, project: project, view_type: 'meetings')
    expect(base.ordered_columns).to eq(%w[title participants creator])
    expect(base.pinned_column_keys).to eq(%w[creator])
    expect(ViewConfiguration.for_user_project(user, project, 'tickets').ordered_columns).to include('number')
    expect(ViewConfiguration.for_user_project(user, other_project, 'meetings').ordered_columns).to eq(%w[title occurred_at duration_minutes participants])
    patch columns_organisation_smart_folder_path(organisation, saved), params: { cols: %w[updated_at occurred_at], pins: %w[updated_at number invalid] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(saved.reload.ordered_columns).to eq(%w[title updated_at occurred_at])
    expect(saved.pinned_column_keys).to eq(%w[updated_at])
    expect(base.reload.ordered_columns).to eq(%w[title participants creator])
    patch columns_path, params: { cols: base.ordered_columns, pins: [''] }
    expect(response).to have_http_status(:ok)
    expect(base.reload.pinned_column_keys).to eq([])
    patch columns_path, params: { cols: %w[number] }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(base.reload.ordered_columns).to eq(%w[title participants creator])
  end

  it 'renders shared view columns but refuses writes without edit rights' do
    saved = folder(owner: create(:user), is_public: true, display_columns: { table_columns: %w[title creator] })
    page = list(smart_folder_id: saved.id)
    expect(page.find('[data-column-picker-editable-value]')['data-column-picker-editable-value']).to eq('false')
    expect(page.all('#column-picker input[type=checkbox]').all?(&:disabled?)).to be(true)
    patch columns_organisation_smart_folder_path(organisation, saved), params: { cols: %w[title updated_at] }, as: :json
    expect(response).not_to have_http_status(:ok)
    expect(saved.reload.ordered_columns).to eq(%w[title creator])
    patch update_from_filters_organisation_smart_folder_path(organisation, saved), params: { filter: { creator: [user.id] } }, as: :json
    expect(response).not_to have_http_status(:ok)
    expect(saved.smart_folder_rules).to be_empty
  end

  it 'keeps complete list state on validation errors, update, and deletion' do
    meeting = record('Context', notes: 'Content')
    saved = folder
    state = { search: 'Context', search_mode: 'title_only', smart_folder_id: saved.id, filter: { creator: [user.id] },
              filter_op: { creator: 'or' }, filter_drop: ['participant'], sort: { column: 'title', direction: 'asc' }, page: 1, items: 10 }
    patch organisation_project_meeting_path(organisation, project, meeting), params: state.merge(meeting: { title: '' }), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:unprocessable_content)
    form = Capybara.string(Nokogiri::HTML.fragment(response.body).at_css('template').inner_html)
    expect(form).to have_css('input[name="filter[creator][]"]', visible: :all)
    expect(form).to have_css('input[name="smart_folder_id"]', visible: :all)
    patch organisation_project_meeting_path(organisation, project, meeting), params: state.merge(meeting: { title: 'Context updated' })
    expect(response).to have_http_status(:redirect)
    expect(Rack::Utils.parse_nested_query(URI(response.location).query)).to include('search_mode' => 'title_only', 'filter' => { 'creator' => [user.id] }, 'items' => '10')
    delete organisation_project_meeting_path(organisation, project, meeting), params: state
    expect(response).to have_http_status(:redirect)
    expect(Rack::Utils.parse_nested_query(URI(response.location).query)).to include('smart_folder_id' => saved.id, 'filter_drop' => ['participant'])
  end
  it 'keeps ticket metadata private when a meeting-only member changes the editor context' do
    create(:ticket_attribute_definition, :select, project: project, name: 'internal_ticket_field')
    record('Visible', names: ['Anna'])
    get new_organisation_smart_folder_path(organisation), params: { project_id: project.id, return_to: 'meetings', context_type: 'All' }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('custom_internal_ticket_field')
    get organisation_field_operators_path(organisation, field: 'custom_internal_ticket_field'),
        params: { project_id: project.id, context_type: 'Meeting' }
    expect(response).to have_http_status(:bad_request)
    get organisation_reference_options_path(organisation, field: 'custom_internal_ticket_field'),
        params: { project_id: project.id, context_type: 'Meeting' }
    expect(response).to have_http_status(:bad_request)
    get organisation_reference_options_path(organisation, field: 'participant'),
        params: { project_id: project.id, context_type: 'Meeting' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['options']).to include('value' => 'anna', 'label' => 'Anna')
  end

  it 'escapes quotes in participant and creator tooltip attributes' do
    payload = 'Eve" onfocus="alert(1)'
    user.update!(first_name: payload, last_name: 'Creator')
    record('Unsafe names', names: [payload])
    config = ViewConfiguration.for_user_project(user, project, 'meetings')
    config.ordered_columns = %w[title participants creator]
    config.save!
    document = list
    expect(document).not_to have_css('[onfocus]', visible: :all)
    expect(document.find('td[data-column="participants"] div.truncate')['title']).to eq(payload)
    expect(document.find('td[data-column="creator"] div.truncate')['title']).to include(payload)
  end

  it 'ignores malformed list filter parameters without raising from pagination' do
    record('Visible')
    %w[x].each { |value| expect(ids(list(filter: value)).size).to eq(1) }
    expect(ids(list(filter: ['x'])).size).to eq(1)
  end

  it 'renders only the list frame while a detail with a large transcript is open' do
    meeting = record('Open', transcript: 'Private transcript content ' * 100)
    expect(MeetingTicketSuggestionRun).not_to receive(:recover_for_meeting!)
    get organisation_project_meetings_path(organisation, project),
        params: { meeting_id: meeting.id, search: 'Open', sort: { column: 'title', direction: 'asc' } },
        headers: { 'Turbo-Frame' => 'meetings_results' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="meetings_results"')
    expect(response.body).not_to include('Private transcript content', 'id="meeting-header"', '<html')
  end

  it 'does not publish meeting filter names or conditions to a knowledge-only reader' do
    create(:note, organisation: organisation, project: project, creator: user, title: 'Visible knowledge')
    saved = folder(name: 'Secret meeting view', is_public: true)
    group = saved.smart_folder_rule_groups.create!(position: 1)
    group.smart_folder_rules.create!(field: 'participant', operator: 'has_any_of', value: '["Confidential Person"]', position: 1)
    project.project_permissions.find_by!(user: user).update!(meetings_access: 'no_access', notes_access: 'read_only')
    [nil, saved.id].each do |id|
      get organisation_project_knowledge_index_path(organisation, project), params: { smart_folder_id: id }
      expect(response).to have_http_status(:ok)
      expect(Capybara.string(response.body)).to have_css('[data-controller~="filter-bar"]')
      expect(response.body).not_to include('Secret meeting view', 'Confidential Person')
    end
    expect(SmartFolderPolicy.new(user, saved)).not_to be_show
  end

  it 'requires meeting access for an explicit Meeting target even when posted from knowledge' do
    project.project_permissions.find_by!(user: user).update!(meetings_access: 'no_access', notes_access: 'read_write')
    expect do
      post create_from_filters_organisation_smart_folders_path(organisation), params: {
        project_id: project.id, return_to: 'knowledge', target_object_type: 'Meeting',
        smart_folder_name: 'Forged meeting view', filter: { tag: ['secret'] }
      }
    end.not_to change(SmartFolder, :count)
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects ticket-only conditions for Meeting targets even with meeting access' do
    expect do
      post create_from_filters_organisation_smart_folders_path(organisation), params: {
        project_id: project.id, return_to: 'knowledge', target_object_type: 'Meeting',
        smart_folder_name: 'Invalid view', filter: { creator: [user.id], tag: ['ignored'] }
      }
    end.not_to change(SmartFolder, :count)
    saved = folder
    group = saved.smart_folder_rule_groups.create!(position: 1)
    expect(group.smart_folder_rules.build(field: 'tag', operator: 'has', value: 'ignored', position: 1)).not_to be_valid
  end

  it 'keeps the All editor and rule validation within its supported type set' do
    saved = folder(target_object_type: 'All')
    get edit_organisation_smart_folder_path(organisation, saved), params: { modal: true }
    expect(response).to have_http_status(:ok)
    page = Capybara.string(response.body)
    expect(page).not_to have_css('select[name$="[field]"] option[value="participant"]', visible: :all)
    expect(page).not_to have_css('select[name$="[field]"] option[value="occurred_at"]', visible: :all)
    expect(page).to have_css('select[name$="[field]"] option[value="creator"]', visible: :all)
    group = saved.smart_folder_rule_groups.create!(position: 1)
    expect(group.smart_folder_rules.build(field: 'participant', operator: 'has_any_of', value: '["Anna"]', position: 1)).not_to be_valid
  end

  it 'rejects missing, foreign or expert conditions instead of silently replacing the rule tree' do
    saved = folder
    group = saved.smart_folder_rule_groups.create!(position: 1)
    rule = group.smart_folder_rules.create!(field: 'participant', operator: 'has_any_of', value: '["Anna"]', position: 1)
    [{}, { filter: { tag: ['ignored'] }, clear_filters: '1' }, { filter: 'x', clear_filters: '1' },
     { filter: { occurred_at: ['unknown'] } }, { filter: { occurred_at: ['today'] }, filter_op: { occurred_at: 'not' } }].each do |input|
      patch update_from_filters_organisation_smart_folder_path(organisation, saved), params: input, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(saved.reload.smart_folder_rules.pluck(:id)).to eq([rule.id])
    end
    rule.update!(field: 'title', operator: 'contains', value: 'Expert only')
    patch update_from_filters_organisation_smart_folder_path(organisation, saved), params: { clear_filters: '1' }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(rule.reload.value).to eq('Expert only')
  end

  it 'carries search, paging and the open detail through naming and the expert editor' do
    meeting = record('Context', names: ['Anna'])
    context = { search: 'Context', search_mode: 'title_only', items: 10, meeting_id: meeting.id }
    post create_from_filters_organisation_smart_folders_path(organisation), params: {
      project_id: project.id, return_to: 'meetings', target_object_type: 'Meeting', smart_folder_name: 'Context view',
      filter: { participant: ['Anna'] }, list_context: context
    }
    saved = SmartFolder.find_by!(name: 'Context view')
    expect(Rack::Utils.parse_nested_query(URI(response.location).query)).to include(context.stringify_keys.transform_values(&:to_s))
    get edit_organisation_smart_folder_path(organisation, saved), params: { modal: true, return_to: 'meetings', list_context: context }
    expect(response).to have_http_status(:ok)
    expect(Capybara.string(response.body)).to have_css('input[name="list_context[search_mode]"][value="title_only"]', visible: :all)
    patch organisation_smart_folder_path(organisation, saved), params: {
      return_to: 'meetings', list_context: context, smart_folder: { name: 'Renamed context' }
    }
    expect(Rack::Utils.parse_nested_query(URI(response.location).query)).to include('search' => 'Context', 'meeting_id' => meeting.id, 'smart_folder_id' => saved.id)
  end
  it 'paginates the folder page in SQL and omits transcript fields from JSON' do
    saved = folder(sort_column: 'title', sort_direction: 'asc')
    meetings = 3.times.map { |n| record("Page #{n}", transcript: 'Transcript must not be loaded') }
    instantiated = 0
    observer = ->(_name, _start, _finish, _id, payload) { instantiated += payload[:record_count] if payload[:class_name] == 'Meeting' }
    ActiveSupport::Notifications.subscribed(observer, 'instantiation.active_record') do
      get organisation_smart_folder_path(organisation, saved), params: { page: 2, per_page: 1 }, as: :json
    end
    expect(response).to have_http_status(:ok)
    expect(instantiated).to eq(1)
    expect(response.parsed_body.fetch('items').map { |item| item.fetch('id') }).to eq([meetings[1].id])
    expect(response.parsed_body.fetch('pagination').fetch('count')).to eq(3)
    expect(response.parsed_body.fetch('items').first.keys).not_to include('transcript', 'notes', 'plain_text_version', 'generated_summary')
    get organisation_smart_folder_path(organisation, saved), params: { page: 2, per_page: 1 }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Page 1')
    expect(response.body).not_to include('Page 0', 'Page 2', 'Transcript must not be loaded')
    expect(Capybara.string(response.body).find_link(I18n.t('generic.back_to_list', default: 'Zurück zur Übersicht'))[:href]).to eq(organisation_project_meetings_path(organisation, project))
  end

  it 'renders the sentence frame without loading the open meeting detail' do
    meeting = record('Open sentence', names: ['Anna'], transcript: 'Private transcript')
    expect(MeetingTicketSuggestionRun).not_to receive(:recover_for_meeting!)
    get organisation_project_meetings_path(organisation, project),
        params: { meeting_id: meeting.id, filter: { participant: ['Anna'] } },
        headers: { 'Turbo-Frame' => 'meetings_results_sentence' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="meetings_results_sentence"', 'Anna')
    expect(response.body).not_to include('Private transcript', 'id="meeting-header"', '<html')
  end

  it 'offers creators to meeting-only readers through the editor endpoint' do
    project.project_permissions.find_by!(user: user).update!(meetings_access: 'read_only', tickets_access: 'no_access')
    get organisation_reference_options_path(organisation, 'creator'), params: { project_id: project.id, context_type: 'Meeting' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('options').map { |option| option.fetch('value') }).to include(user.id)
  end

  it 'keeps an empty meeting view empty when saving its expert editor' do
    saved = folder
    get edit_organisation_smart_folder_path(organisation, saved), params: { modal: true }
    expect(response).to have_http_status(:ok)
    expect(Capybara.string(response.body)).not_to have_css('[data-smart-folder-form-target="ruleGroupsContainer"] select', visible: :all)
    patch organisation_smart_folder_path(organisation, saved), params: { smart_folder: { name: 'Still empty', sort_column: 'title' } }
    expect(response).to have_http_status(:redirect)
    expect(saved.reload.name).to eq('Still empty')
    expect(saved.smart_folder_rules).to be_empty
    patch organisation_smart_folder_path(organisation, saved), params: { smart_folder: { name: '' } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(Capybara.string(response.body)).not_to have_css('[data-smart-folder-form-target="ruleGroupsContainer"] select', visible: :all)
  end

  it 'keeps the pins every own meeting view shows when applying columns to all' do
    patch columns_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings'),
          params: { cols: %w[participants creator], pins: %w[creator] }, as: :json
    expect(response).to have_http_status(:ok)
    saved = folder(display_columns: { table_columns: %w[title participants], pinned_columns: %w[participants] })
    second = folder(name: 'Creator pinned', display_columns: { table_columns: %w[title creator], pinned_columns: %w[creator] })
    following = folder(name: 'Follows the base view')
    emptied = folder(name: 'Empty list').tap { |view| view.update_columns(display_columns: {}) }
    scalar = folder(name: 'Broken list').tap { |view| view.update_columns(display_columns: 'broken') }
    legacy = folder(name: 'Legacy').tap do |view|
      view.update_columns(display_columns: { 'table_columns' => %w[title], 'list_columns' => { 'cells' => %w[creator], 'metadata' => [] } })
    end
    project.project_permissions.find_by!(user: user).update!(tickets_access: 'read_only')
    ticket_view = folder(name: 'Tickets', target_object_type: 'Ticket', display_columns: { table_columns: %w[number title assignees] })
    expect([following, emptied, scalar].map(&:pinned_column_keys)).to eq([nil, nil, nil])
    patch apply_columns_to_all_organisation_project_view_configuration_path(organisation, project), params: {
      view_type: 'meetings', view_configuration: { table_columns: %w[title participants creator] }
    }
    expect(response).to have_http_status(:see_other)
    expect(saved.reload.ordered_columns).to eq(%w[title participants creator])
    expect(saved.pinned_column_keys).to eq(%w[participants])
    expect(second.reload.pinned_column_keys).to eq(%w[creator])
    [following, emptied, scalar].each do |view|
      expect(view.reload.ordered_columns).to eq(%w[title participants creator])
      expect(view.pinned_column_keys).to eq(%w[creator])
    end
    expect(legacy.reload.display_columns).not_to have_key('list_columns')
    expect(legacy.ordered_columns).to eq(%w[title participants creator])
    expect(legacy.pinned_column_keys).to eq([])
    expect(ticket_view.reload.ordered_columns).to eq(%w[number title assignees])
  end

  it 'returns 403 without changing columns when the reader lacks meeting access' do
    project.project_permissions.find_by!(user: user).update!(meetings_access: 'no_access', tickets_access: 'read_only')
    expect do
      patch columns_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings'),
            params: { cols: %w[title creator] }, as: :json
    end.not_to change(ViewConfiguration, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it 'lets a meeting reader create, reopen and delete an organisation-wide view' do
    post organisation_smart_folders_path(organisation), params: { smart_folder: { name: 'Across projects', target_object_type: 'Meeting' } }
    expect(response).to have_http_status(:redirect)
    saved = SmartFolder.find_by!(name: 'Across projects')
    expect(saved.project_id).to be_nil
    expect(response).to redirect_to(organisation_smart_folder_path(organisation, saved))
    visible = record('Readable')
    create(:meeting, organisation: organisation, project: other_project, creator: user, title: 'Forbidden project')
    get organisation_smart_folder_path(organisation, saved), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('items').map { |item| item.fetch('id') }).to eq([visible.id])
    delete organisation_smart_folder_path(organisation, saved)
    expect(SmartFolder.exists?(saved.id)).to be(false)
    expect(response).to redirect_to(organisation_meetings_path(organisation))
  end

  it 'excludes Meeting views from dashboard settings and forged ticket widget selections' do
    saved = folder(name: 'Private meeting metadata', is_public: true)
    folder(name: 'Available ticket view', target_object_type: 'Ticket')
    record('Meeting must not become a ticket')
    project.project_permissions.find_by!(user: user).update!(meetings_access: 'no_access', tickets_access: 'read_only')
    get edit_organisation_project_dashboard_configuration_path(organisation, project)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Available ticket view')
    expect(response.body).not_to include(saved.name)
    post widget_preview_organisation_project_dashboard_configuration_path(organisation, project),
         params: { widget: { key: 'smart_folder_tickets', folder_id: saved.id } }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('dashboard.smart_folder_tickets.unavailable_message'))
    expect(response.body).not_to include(saved.name, 'Meeting must not become a ticket')
  end
  it 'clamps an out-of-range JSON page of a Meeting view to its last page' do
    saved = folder(sort_column: 'title', sort_direction: 'asc')
    meetings = 3.times.map { |n| record("Page #{n}") }
    get organisation_smart_folder_path(organisation, saved), params: { page: 99, per_page: 2 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('items').map { |item| item.fetch('id') }).to eq([meetings.last.id])
  end

  it 'offers dashboard widgets only the ticket views the reader may see' do
    project.project_permissions.find_by!(user: user).update!(tickets_access: 'read_only')
    stranger = create(:user)
    private_view = folder(owner: stranger, name: 'Private ticket view', target_object_type: 'Ticket')
    shared_view = folder(owner: stranger, name: 'Shared ticket view', target_object_type: 'Ticket')
    create(:smart_folder_share, smart_folder: shared_view, user: user)
    meeting_view = folder(name: 'Readable meeting view', is_public: true)
    get edit_organisation_project_dashboard_configuration_path(organisation, project)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Shared ticket view')
    expect(response.body).not_to include('Private ticket view', 'Readable meeting view')
    [private_view, meeting_view].each do |saved|
      post widget_preview_organisation_project_dashboard_configuration_path(organisation, project),
           params: { widget: { key: 'smart_folder_tickets', folder_id: saved.id } }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('dashboard.smart_folder_tickets.unavailable_message'))
      expect(response.body).not_to include(saved.name)
    end
  end

  it 'offers participant names only from readable meetings of the requested project' do
    create(:project_permission, project: other_project, user: user, meetings_access: 'read_only')
    record('Here', names: ['Anna'])
    create(:meeting, project: other_project, organisation: organisation, creator: user, title: 'Elsewhere').tap do |meeting|
      create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Other Project Person')
    end
    hidden_project = create(:project, organisation: organisation)
    create(:meeting, project: hidden_project, organisation: organisation, creator: user, title: 'Hidden').tap do |meeting|
      create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Hidden Person')
    end
    labels = lambda do |**scope|
      get organisation_reference_options_path(organisation, field: 'participant'), params: { context_type: 'Meeting', **scope }
      expect(response).to have_http_status(:ok)
      response.parsed_body.fetch('options').map { |option| option['label'] }
    end
    expect(labels.call(project_id: project.id)).to eq(['Anna'])
    expect(labels.call).to contain_exactly('Anna', 'Other Project Person')
    saved = folder(project: nil)
    saved.smart_folder_rule_groups.create!(position: 1)
         .smart_folder_rules.create!(field: 'participant', operator: 'has_any_of', value: '["Anna"]', position: 1)
    get edit_organisation_smart_folder_path(organisation, saved), params: { modal: true }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Anna')
    expect(response.body).not_to include('Hidden Person')
  end

  it 'keeps Meeting views out of knowledge and ignores views of other projects there' do
    project.project_permissions.find_by!(user: user).update!(notes_access: 'read_only')
    create(:project_permission, project: other_project, user: user, notes_access: 'read_only', meetings_access: 'read_only')
    create(:note, organisation: organisation, project: project, creator: user, title: 'Local note')
    bound = folder(name: 'Bound meeting view')
    org_wide = folder(name: 'Org meeting view', project: nil, is_public: true)
    foreign = folder(name: 'Foreign note view', project: other_project, target_object_type: 'Note')
    foreign.smart_folder_rule_groups.create!(position: 1)
           .smart_folder_rules.create!(field: 'title', operator: 'contains', value: 'Nothing here', position: 1)
    [bound, org_wide, foreign].each do |saved|
      get organisation_project_knowledge_index_path(organisation, project), params: { smart_folder_id: saved.id }
      expect(response).to have_http_status(:ok)
      page = Capybara.string(response.body)
      expect(page).to have_text('Local note')
      expect(page).not_to have_css('[role="tab"]', text: saved.name)
    end
    get organisation_project_knowledge_index_path(organisation, project), params: { type: 'meeting' }
    expect(response).to have_http_status(:ok)
    bar = Capybara.string(response.body).find('[data-filter-bar-type-targets-value]')
    expect(JSON.parse(bar['data-filter-bar-type-targets-value'])).to eq('note' => 'Note', 'document' => 'Document')
  end

  it 'ignores views of another project even when its meetings are readable' do
    create(:project_permission, project: other_project, user: user, meetings_access: 'read_only')
    local = record('Local')
    foreign_folder = folder(project: other_project, name: 'Foreign view')
    expect(list).not_to have_text('Foreign view')
    expect(ids(list(smart_folder_id: foreign_folder.id))).to eq([local.id])
  end

  it 'offers Meeting views for sharing by meeting access, not by ticket access' do
    saved = folder
    readers = { meeting: %w[read_only no_access], ticket: %w[no_access read_only] }.to_h do |kind, (meetings, tickets)|
      member = create(:user, email: "#{kind}.reader@example.test")
      create(:membership, organisation: organisation, user: member, role: create(:role, organisation: organisation), active: true)
      create(:project_permission, project: project, user: member, meetings_access: meetings, tickets_access: tickets)
      [kind, member]
    end
    get share_organisation_smart_folder_path(organisation, saved)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(readers[:meeting].email)
    expect(response.body).not_to include(readers[:ticket].email)
  end

  it 'refuses a Meeting view bound to a project of another organisation' do
    foreign_project = ActsAsTenant.without_tenant { create(:project, organisation: create(:organisation)) }
    expect do
      post organisation_smart_folders_path(organisation),
           params: { smart_folder: { name: 'Cross tenant', target_object_type: 'Meeting', project_id: foreign_project.id } }
    end.not_to(change { ActsAsTenant.without_tenant { SmartFolder.count } })
  end

  it 'refuses every Meeting view endpoint to a member without meeting access' do
    saved = folder(owner: create(:user), name: 'Guarded view', is_public: true, public_access_level: 2)
    create(:smart_folder_share, smart_folder: saved, user: user, can_edit: true, can_share: true)
    saved.smart_folder_rule_groups.create!(position: 1)
         .smart_folder_rules.create!(field: 'participant', operator: 'has_any_of', value: '["Guarded Person"]', position: 1)
    record('Guarded meeting', names: ['Guarded Person'])
    project.project_permissions.find_by!(user: user).update!(meetings_access: 'no_access', tickets_access: 'read_only')
    requests = [
      -> { get organisation_smart_folder_path(organisation, saved) },
      -> { get organisation_smart_folder_path(organisation, saved), as: :json },
      -> { get edit_organisation_smart_folder_path(organisation, saved), params: { modal: true } },
      -> { patch organisation_smart_folder_path(organisation, saved), params: { smart_folder: { name: 'Changed' } } },
      -> { patch rename_organisation_smart_folder_path(organisation, saved), params: { name: 'Changed' }, as: :json },
      lambda {
        patch update_from_filters_organisation_smart_folder_path(organisation, saved),
              params: { project_id: project.id, filter: { participant: ['Other'] } }, as: :json
      },
      -> { patch columns_organisation_smart_folder_path(organisation, saved), params: { cols: %w[title creator] }, as: :json },
      -> { get share_organisation_smart_folder_path(organisation, saved) },
      -> { post clone_organisation_smart_folder_path(organisation, saved) },
      -> { delete organisation_smart_folder_path(organisation, saved) }
    ]
    requests.each do |request|
      expect { request.call }.not_to change(SmartFolder, :count)
      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include('Guarded Person', 'Guarded meeting')
    end
    expect(saved.reload).to have_attributes(name: 'Guarded view', display_columns: nil)
    expect(saved.smart_folder_rules.pluck(:value)).to eq(['["Guarded Person"]'])
  end

  it 'makes the search field the keyboard entry into the meeting rows' do
    record('Reachable')
    expect(list).to have_css('input[name="search"][data-keyboard-navigation-target="searchInput"]')
  end
end

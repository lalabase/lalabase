# frozen_string_literal: true

require 'rails_helper'

# What: the bulk panel's shell, GET tickets/bulk_edit (doc/ticket_bulk_edit_plan.md, slice 3).
# Type: request spec.
# Why: the shell is content for the lane's frame and nothing else: a frame request
#   gets the panel with its head, the way out and the disabled button, a plain
#   request lands on the list, a reader without write access is turned away like
#   on every write action. The numbers are not in the shell; the templates for
#   them are, as values the panel controller reads.
RSpec.describe 'Ticket bulk edit panel shell', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:panel_path) { bulk_edit_organisation_project_tickets_path(organisation, project) }
  let(:frame_headers) { { 'Turbo-Frame' => 'ticket_display_frame' } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def document
    Nokogiri::HTML(response.body)
  end

  context 'as a writer' do
    before do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      sign_in user
    end

    it 'answers a frame request with the panel inside the lane frame' do
      get panel_path, headers: frame_headers

      expect(response).to have_http_status(:ok)
      frame = document.at_css('turbo-frame#ticket_display_frame')
      expect(frame).to be_present
      panel = frame.at_css('[data-controller="ticket-bulk-panel"]')
      expect(panel).to be_present
      expect(panel['data-action']).to include('ticket-selection:change@window->ticket-bulk-panel#update')
      expect(panel.at_css('[data-ticket-bulk-panel-target="title"]')).to be_present
      expect(panel.at_css('button[data-action="click->ticket-bulk-panel#close"]')).to be_present
      expect(panel.at_css('[data-ticket-bulk-panel-target="changes"]').children.reject(&:text?)).to be_empty
    end

    it 'carries the pluralised templates and a button that cannot act yet' do
      get panel_path, headers: frame_headers

      panel = document.at_css('[data-controller="ticket-bulk-panel"]')
      texts = JSON.parse(panel['data-ticket-bulk-panel-texts-value'])
      expect(texts.dig('title', 'other')).to match(/%\{count\}/)
      expect(texts.dig('execute', 'other')).to match(/%\{count\}/)
      expect(texts.dig('title', 'one')).not_to match(/%\{count\}/)
      expect(texts.dig('stock', 'overwrite', 'other')).to match(/%\{count\}/)
      expect(texts.dig('summary_tickets', 'one')).to be_present
      execute = panel.at_css('[data-ticket-bulk-panel-target="execute"]')
      expect(execute).to be_present
      expect(execute.has_attribute?('disabled')).to be(true)
      expect(execute.at_css('[data-ticket-bulk-panel-target="executeLabel"]')).to be_present
      expect(panel.at_css('[data-ticket-bulk-panel-target="cancel"]').has_attribute?('disabled')).to be(true)
    end

    context 'with fields to change (slice 4)' do
      before do
        create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', position: 1,
                                             labels: { 'de' => 'Status', 'en' => 'Status' },
                                             options: { 'allowed_values' => [{ 'value' => 'open', 'labels' => { 'de' => 'offen', 'en' => 'open' } }] })
        create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date', position: 2,
                                             labels: { 'de' => 'Frist', 'en' => 'Due' }, options: { 'deadline' => true })
        create(:ticket_attribute_definition, project: project, name: 'notes', field_type: 'text', position: 3,
                                             labels: { 'de' => 'Notizen', 'en' => 'Notes' })
        create(:tag, name: 'bug', organisation: organisation)
      end

      it 'renders the picker with one option per offered field under its group, and a row template per field' do
        get panel_path, headers: frame_headers

        panel = document.at_css('[data-controller="ticket-bulk-panel"]')
        expect(panel['data-ticket-bulk-panel-summary-url-value']).to eq(bulk_summary_organisation_project_tickets_path(organisation, project, format: :json))
        expect(panel.at_css('[data-ticket-bulk-panel-target="pickerMenu"]').has_attribute?('hidden')).to be(true)
        options = panel.css('[data-ticket-bulk-panel-target="pickerOption"]')
        expect(options.map { |o| o['data-field'] }).to eq(%w[status due_date tags assignees watchers])
        expect(panel.css('[data-picker-group]').size).to eq(2)
        templates = panel.css('template[data-ticket-bulk-panel-target="rowTemplate"]')
        expect(templates.map { |t| [t['data-field'], t['data-kind']] })
          .to eq([%w[status single], %w[due_date date], %w[tags multi], %w[assignees multi], %w[watchers multi]])
        status_row = Nokogiri::HTML.fragment(templates[0].inner_html)
        expect(status_row.at_css('.tbp-select [data-select-label]').text).to eq('Wert wählen')
        expect(status_row.at_css('[data-select-layer] .tbp-option[data-value="open"]').text.strip).to eq('offen')
        expect(status_row.at_css('select')).to be_nil
        expect(status_row.at_css('[data-stock]')).to be_present
        expect(status_row.at_css('button[data-action="click->ticket-bulk-panel#removeField"]')['data-field']).to eq('status')
        due_row = Nokogiri::HTML.fragment(templates[1].inner_html)
        expect(due_row.at_css('input[type="date"].tbp-control')).to be_present
        expect(due_row.at_css('[data-clear-date][aria-pressed="false"]')).to be_present
        # A multi row: the chips' place, the dashed trigger, the layer with one
        # three-state option per value and the search (slice 5).
        tags_row = Nokogiri::HTML.fragment(templates[2].inner_html)
        expect(tags_row.at_css('[data-multi] [data-chips]')).to be_present
        expect(tags_row.at_css('.tbp-add-value[aria-expanded="false"]').text).to include('Tag')
        layer = tags_row.at_css('[data-values-layer]')
        expect(layer.has_attribute?('hidden')).to be(true)
        expect(layer.css('[role="listbox"] .tbp-option').map { |o| o['data-value'] }).to eq(%w[bug])
        expect(layer.at_css('.tbp-option [data-tri]')).to be_present
        expect(layer.at_css('input[type="search"].tbp-search')).to be_present
        # Only the tags take a name nobody has made yet: the line that offers
        # it waits hidden with the limit the server holds.
        new_value = layer.at_css('button[data-new-value][hidden]')
        expect(new_value['data-max-length']).to eq(Tag::MAX_NAME_LENGTH.to_s)
        expect(new_value['data-template']).to match(/%\{name\}/).and include('neues Tag')
        expect(layer.at_css('input.tbp-search')['data-action']).to include('keydown.enter->ticket-bulk-panel#addNewValue:prevent')
        expect(layer.at_css('[data-new-invalid]').text).to include(Tag::MAX_NAME_LENGTH.to_s)
        # The prototype a created tag is listed from: the same option markup,
        # with the label's own hook.
        prototype = layer.at_css('template[data-option-prototype] .tbp-option')
        expect(prototype['data-action']).to eq('click->ticket-bulk-panel#cycleValue')
        expect(prototype.at_css('[data-option-label]')).to be_present
        people_row = Nokogiri::HTML.fragment(templates[3].inner_html)
        expect(people_row.css('.tbp-option').map { |o| o['data-value'] }).to include(user.id)
        expect(people_row.at_css('[data-new-value], [data-option-prototype]')).to be_nil
      end

      it 'answers the summary for ticked ids with the stock per field' do
        tickets = ActsAsTenant.with_tenant(organisation) do
          [create(:ticket, project: project, organisation: organisation, creator: user, custom_attributes: { 'status' => 'open' }),
           create(:ticket, project: project, organisation: organisation, creator: user, custom_attributes: {})]
        end

        post bulk_summary_organisation_project_tickets_path(organisation, project, format: :json),
             params: { selection: { mode: 'ids', ids: tickets.map(&:id) } }

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json['count']).to eq(2)
        expect(json['fields']['status']['values']).to eq([{ 'value' => 'open', 'label' => 'offen', 'count' => 1 }])
        expect(json['fields']['status']['without']).to eq(1)
        expect(json['fields']['status']['digest']).to be_present
        expect(json['fields']).not_to have_key('notes')
        expect(json['fields']['tags']).to eq({ 'values' => [], 'digest' => json['fields']['tags']['digest'] })
      end

      it 'answers the summary for all hits of the address, and refuses a stale count' do
        ActsAsTenant.with_tenant(organisation) do
          create(:ticket, project: project, organisation: organisation, creator: user, title: 'Bug one')
          create(:ticket, project: project, organisation: organisation, creator: user, title: 'Plain')
        end

        post bulk_summary_organisation_project_tickets_path(organisation, project, format: :json),
             params: { search: 'Bug', search_mode: 'title_only', selection: { mode: 'all', expected_count: 1 } }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['count']).to eq(1)

        post bulk_summary_organisation_project_tickets_path(organisation, project, format: :json),
             params: { search: 'Bug', search_mode: 'title_only', selection: { mode: 'all', expected_count: 5 } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('list_changed')
      end
    end

    it 'sends a plain request to the list' do
      get panel_path

      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
    end
  end

  # The tags layer names tags; a member who writes here but cannot open
  # another project does not learn the names used only there (TagPolicy::Scope).
  context 'as a member who writes in this project only' do
    before do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
      sign_in user
    end

    it 'lists the tags of this project and none from a project it cannot open' do
      ActsAsTenant.with_tenant(organisation) do
        other = create(:project, organisation: organisation)
        create(:tagging, tag: create(:tag, name: 'hier', organisation: organisation),
                         taggable: create(:ticket, project: project, organisation: organisation))
        create(:tagging, tag: create(:tag, name: 'geheim', organisation: organisation),
                         taggable: create(:ticket, project: other, organisation: organisation))
      end

      get panel_path, headers: frame_headers

      expect(response).to have_http_status(:ok)
      tags_template = document.at_css('template[data-field="tags"]')
      values = Nokogiri::HTML.fragment(tags_template.inner_html).css('[role="listbox"] .tbp-option').map { |o| o['data-value'] }
      expect(values).to eq(['hier'])
      expect(response.body).not_to include('geheim')
    end
  end

  context 'as a reader (tickets read_only)' do
    before do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
      sign_in user
    end

    it 'is turned away like on every write action' do
      get panel_path, headers: frame_headers

      # ObjectListController#authorize_project_access asks for :write on every
      # action but index and show and sends the reader to the project page.
      expect(response).to redirect_to(organisation_project_path(organisation, project))
      expect(flash[:alert]).to be_present
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Stored XSS through the colour of an attribute option (security test 26.09.2026).
# The colour went unchecked from `option_colors[]` into the jsonb options, and the ticket
# header wrote it into a raw `"style=\"...\"".html_safe`. Three layers close it, and each
# must hold alone: the controller normalises, the model validates, the output only ever
# prints a hex value. The render examples write the colour with update_column, past the
# first two layers, the way a legacy row already in the database would arrive.
RSpec.describe 'Attribute option colour: stored XSS and CSS injection', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:xss) { '#000"><img src=x onerror=alert(1)>' }
  let(:css_injection) { 'red; background-image:url(https://evil.example/track)' }

  # The option carrying the colour has no system function: with one, the ladder class from
  # TicketColorMap wins and the colour is never read. The second option lets the kanban find
  # its status field by function and gives the merge page a target.
  let!(:status) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'doing', 'labels' => { 'de' => 'In Arbeit', 'en' => 'Doing' } },
                                             { 'value' => 'new', 'labels' => { 'de' => 'Neu', 'en' => 'New' },
                                               'system_functions' => [SystemFunctions::Registry::IS_NEW] }
                                           ] })
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  # A legacy row: the colour goes in without passing the model validation.
  def store_color(color)
    options = status.options.deep_dup
    options['allowed_values'].first['color'] = color
    status.update_column(:options, options)
  end

  def stored_color
    status.reload.options['allowed_values'].first['color']
  end

  def page
    Nokogiri::HTML(response.body)
  end

  describe 'PATCH update with a manipulated option_colors[]' do
    def update_with(colors)
      patch organisation_project_ticket_attribute_definition_path(organisation, project, status),
            params: { ticket_attribute_definition: { field_type: 'select', options: %w[doing new],
                                                     option_colors: colors } }
    end

    it 'stores a colour the form picked' do
      update_with(%w[#3B82F6 #22c55e])

      expect(response).to have_http_status(:redirect)
      expect(stored_color).to eq('#3B82F6')
    end

    it 'stores the fallback instead of an XSS payload' do
      update_with([xss, '#22c55e'])

      expect(response).to have_http_status(:redirect)
      expect(stored_color).to eq('#000000')
    end

    it 'stores the fallback instead of a CSS injection' do
      update_with([css_injection, '#22c55e'])

      expect(stored_color).to eq('#000000')
    end

    it 'stores the fallback for an option the request sent no colour for' do
      update_with(['#3B82F6'])

      expect(status.reload.options['allowed_values'].map { |option| option['color'] }).to eq(%w[#3B82F6 #000000])
    end

    it 'heals a legacy row on the next save through the editor' do
      store_color(xss)

      update_with(%w[#3B82F6 #22c55e])

      expect(response).to have_http_status(:redirect)
      expect(stored_color).to eq('#3B82F6')
    end

    it 'strips surrounding whitespace from a valid colour' do
      update_with([" #3b82f6\n", '#22c55e'])

      expect(stored_color).to eq('#3b82f6')
    end
  end

  describe 'ticket header (status badge in the colored display mode)' do
    let!(:ticket) do
      create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'doing' })
    end

    before do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                                table_columns: %w[number title], header_columns: %w[status])
    end

    def badge
      page.at_css('button[data-inline-status-target="badge"]')
    end

    def menu_dot
      page.at_css('[data-inline-status-target="menu"] button[data-value="doing"] span')
    end

    it 'carries a valid colour on the badge and the menu dot (proves the spot renders)' do
      store_color('#3B82F6')

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(badge['style']).to eq('background-color: #3B82F6; color: #FFFFFF')
      expect(menu_dot['style']).to eq('background-color: #3B82F6; color: #FFFFFF')
    end

    it 'does not turn a stored XSS payload into markup' do
      store_color(xss)

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(page.css('img[src="x"]')).to be_empty
      expect(page.css('[onerror]')).to be_empty
      expect(badge).to be_present
      expect(badge['style'].to_s).not_to include('img')
      expect(menu_dot['style'].to_s).not_to include('img')
    end

    # The escaping layer on its own: even if the helper handed over a hostile style
    # (a future bug in status_badge_style), the view must print it as attribute text.
    it 'escapes the style attribute even when the helper returns a hostile value' do
      store_color('#3B82F6')
      allow_any_instance_of(TicketsHelper).to receive(:status_badge_style).and_return(style: xss)

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(page.css('img[src="x"]')).to be_empty
      expect(page.css('[onerror]')).to be_empty
      expect(badge['style']).to eq(xss)
      expect(menu_dot['style']).to eq(xss)
    end

    # The request examples reach the status badge and its menu. Priority and custom
    # fields repeat the same markup four more times; this keeps all six on the
    # escaping path without building three more pages.
    it 'builds no style attribute of the header by hand' do
      source = Rails.root.join('app/views/organisations/tickets/_ticket_metadata_row.html.erb').read

      expect(source.scan('tag.attributes(style:').size).to eq(6)
      expect(source).not_to match(/style=\\?".*html_safe/)
    end

    it 'does not print a stored CSS injection into the style' do
      store_color(css_injection)

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(badge).to be_present
      expect(response.body).not_to include('evil.example')
    end
  end

  describe 'the other outputs of the same colour' do
    it 'keeps a CSS injection out of the attribute list' do
      store_color('#3B82F6')
      get organisation_project_ticket_attribute_definitions_path(organisation, project)
      expect(response.body).to include('background-color: #3B82F6')

      store_color(css_injection)
      get organisation_project_ticket_attribute_definitions_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('evil.example')
    end

    it 'keeps a CSS injection out of the merge page' do
      store_color('#3B82F6')
      get merge_option_organisation_project_ticket_attribute_definition_path(organisation, project, status,
                                                                             source_value: 'doing')
      expect(response.body).to include('background-color: #3B82F6')

      store_color(css_injection)
      get merge_option_organisation_project_ticket_attribute_definition_path(organisation, project, status,
                                                                             source_value: 'doing')

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('evil.example')
    end

    it 'shows the fallback in the editor instead of a legacy value' do
      store_color('#3B82F6')
      get edit_organisation_project_ticket_attribute_definition_path(organisation, project, status)
      expect(page.css('input[type="color"]').map { |input| input['value'] }).to include('#3B82F6')

      store_color(css_injection)
      get edit_organisation_project_ticket_attribute_definition_path(organisation, project, status)

      expect(response).to have_http_status(:ok)
      expect(page.css('input[type="color"]').first['value']).to eq('#000000')
      expect(response.body).not_to include('evil.example')
    end

    it 'keeps a CSS injection out of the kanban column dot' do
      ViewConfiguration.create!(user: user, project: project, organisation: organisation,
                                view_type: 'tickets', view_mode: 'kanban',
                                table_columns: %w[number title], header_columns: %w[assignees],
                                list_columns: { 'cells' => [], 'metadata' => [] })

      store_color('#3B82F6')
      get organisation_project_tickets_path(organisation, project)
      expect(page.css('.kanban-column-dot').map { |dot| dot['style'] }).to include('background-color: #3B82F6;')

      store_color(css_injection)
      get organisation_project_tickets_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('evil.example')
    end
  end
end

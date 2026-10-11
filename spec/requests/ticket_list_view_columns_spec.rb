# frozen_string_literal: true

require 'rails_helper'

# What: the ticket list renders ONE ordered column list by rank (doc/spaltenwahl_plan.md, S1).
# Type: request spec against the index and the three post streams that re-render a row.
# Why: the stylesheet shows a cell or its item below the title by data-rank against the
#   table's data-fit; the ranks come from Tickets::ResolveColumns with two sources
#   (folder, base view). A wrong source or rank shows the wrong column, and a
#   streamed row without ranks would lose its columns silently.
RSpec.describe 'Ticket list columns', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:membership) { ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation)) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Spalten pruefen') } }
  let!(:view_configuration) do
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                                table_columns: %w[number title assignees created_at],
                                header_columns: %w[assignees])
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    membership
    ticket
    sign_in user
  end

  def header_cell(body, rank)
    body[/<th[^>]*data-rank="#{rank}"[^>]*>/]
  end

  describe 'GET index' do
    it 'renders the ranked header cells in the saved order with their minimum widths' do
      get organisation_project_tickets_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(header_cell(response.body, 1)).to include('data-col-min="120"') # assignees
      expect(header_cell(response.body, 2)).to include('data-col-min="110"') # created_at
      expect(header_cell(response.body, 3)).to be_nil
      expect(response.body).to include('data-column-count="4"')
    end

    it 'writes the first data-fit: all ranked columns with the detail closed' do
      get organisation_project_tickets_path(organisation, project)
      expect(response.body).to include('data-fit="2"')
    end

    it 'writes data-fit 1 while a ticket is selected (the detail is open)' do
      get organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      expect(response.body).to include('data-fit="1"')
    end

    # Both forms are rendered, and exactly one of them shows. Until 07.09.2026
    # both showed, which made a row three or four lines tall the moment the
    # detail opened; between then and the evening of the same day the second
    # form was gone entirely and a field that did not fit was simply lost.
    it 'renders one cell per ranked field, and one meta item that shows only when the cell has gone' do
      get organisation_project_tickets_path(organisation, project)
      row = response.body[%r{<tr[^>]*data-ticket-id="#{ticket.id}".*?</tr>}m]

      expect(row).to include('assignees-column')
      expect(row).to match(/data-rank="1"\s+data-column="assignees"/)

      # One CELL per ranked field.
      expect(row.scan(/data-column="assignees"/).size).to eq(1)
      expect(row.scan(/data-column="created_at"/).size).to eq(1)
      expect(row).not_to include('column-inline')

      # And one meta item per ranked field, under the title. The two are never
      # SHOWN at once: the stylesheet reveals an item exactly when its cell's
      # rank is beyond the table's data-fit (layout.css, "The meta line under
      # the title"). Rendering both AND showing both is what made rows three and
      # four lines high before 07.09.2026.
      expect(row.scan(/class="ticket-meta__item"/).size).to eq(2)
    end

    it 'takes the columns of the active folder when the folder has its own' do
      # A folder without a rule matches nothing and renders no table at all.
      folder = create(:smart_folder, user: user, organisation: organisation, project: project,
                                     target_object_type: 'Ticket',
                                     display_columns: { 'table_columns' => %w[number title created_at] })
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Spalten')

      get organisation_project_tickets_path(organisation, project, smart_folder_id: folder.id)

      expect(response.body).to include('data-column-count="3"')
      expect(header_cell(response.body, 1)).to include('data-col-min="110"')
    end

    it 'folds the legacy second list in behind the table columns' do
      view_configuration.update_columns(list_columns: { 'cells' => %w[tags], 'metadata' => [] })

      get organisation_project_tickets_path(organisation, project)

      expect(response.body).to include('data-column-count="5"')
      expect(header_cell(response.body, 3)).to include('data-col-min="140"') # tags
    end
  end

  describe 'the column picker (S2)' do
    it 'renders the trigger as a sign that knows its count, and the panel with one row per field beyond number and title' do
      get organisation_project_tickets_path(organisation, project)

      expect(response.body).to include('data-column-picker-trigger')
      # The trigger carries no label beside its icon (user, 07.09.2026): the
      # right end of a narrow head holds the search and this sign, and nothing
      # else. The count lives in the title, where the sentence fits at every
      # width - a label that fits only sometimes is one a width rule has to keep
      # taking away.
      expect(response.body).to include('title="Spalten wählen"')
      expect(response.body).not_to include('Spalten wählen ·')
      # Every ranked column carries its minimum AND its share, read by one rule.
      expect(response.body).to match(/style="--col-min: \d+px; --col-share: \d+%"/)
      expect(response.body).not_to include('4 Spalten')
      expect(response.body).to include('id="column-picker"')
      rows = response.body.scan(/<li class="column-picker__row"[^>]*data-key="([^"]+)"/m).flatten
      expect(rows.first(2)).to eq(%w[assignees created_at]) # the ticked ones first, in rank order
      expect(rows).not_to include('number', 'title')
      expect(rows.size).to eq(view_configuration.available_columns.size - 2)
      expect(response.body).to include("data-column-picker-save-url-value=\"#{columns_organisation_project_view_configuration_path(organisation, project)}\"")
      expect(response.body).to include('data-column-picker-editable-value="true"')
    end

    it 'saves into the active folder, and shows a read-only shared view without a tick to take' do
      # The reader is a plain member with ticket access: an account admin may
      # update any folder (SmartFolderPolicy#update?), so nothing would be read-only.
      membership.update!(role: create(:role, organisation: organisation, title: 'member'))
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
      colleague = create(:user)
      create(:membership, user: colleague, organisation: organisation, role: create(:admin_role, organisation: organisation, title: 'Admin 2'))
      folder = create(:smart_folder, user: colleague, organisation: organisation, project: project, target_object_type: 'Ticket')
      create(:smart_folder_share, smart_folder: folder, user: user, can_edit: false)
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Spalten')

      get organisation_project_tickets_path(organisation, project, smart_folder_id: folder.id)

      expect(response.body).to include("data-column-picker-save-url-value=\"#{columns_organisation_smart_folder_path(organisation, folder)}\"")
      expect(response.body).to include('data-column-picker-editable-value="false"')
      expect(response.body).to include(I18n.t('components.column_picker.read_only'))
      expect(response.body).to match(/<li class="column-picker__row"[^>]*data-key="assignees".*?<input type="checkbox"[^>]*disabled/m)
    end
  end

  describe 'the base view endpoint the picker saves into (S3)' do
    let(:json) { { 'ACCEPT' => 'application/json' } }

    it 'stores the list, required first, and retires the legacy second list' do
      view_configuration.update_columns(list_columns: { 'cells' => %w[tags], 'metadata' => [] })

      patch columns_organisation_project_view_configuration_path(organisation, project), params: { cols: %w[created_at title assignees] }, headers: json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('success' => true, 'columns' => %w[number title created_at assignees])
      expect(view_configuration.reload.list_columns).to be_nil
      expect(view_configuration.ordered_columns).to eq(%w[number title created_at assignees])
    end

    it 'refuses a key the reader may not see, and an empty request, with 422 and leaves the list alone' do
      patch columns_organisation_project_view_configuration_path(organisation, project), params: { cols: %w[assignees nope] }, headers: json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['success']).to be false

      patch columns_organisation_project_view_configuration_path(organisation, project), params: {}, headers: json
      expect(response).to have_http_status(:unprocessable_content)

      expect(view_configuration.reload.ordered_columns).to eq(%w[number title assignees created_at])
    end
  end

  describe 'a row re-rendered by a post stream keeps its ranks' do
    let!(:existing_post) { create(:post, ticket: ticket, user: user, content: 'Original content') }
    let(:stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

    def expect_ranked_row(body)
      expect(body).to include('number-column')
      expect(body).to include('title-column')
      expect(body).to match(/data-rank="1"\s+data-column="assignees"/)
      expect(body).to match(/data-rank="2"\s+data-column="created_at"/)
    end

    it 'on create' do
      post organisation_project_ticket_posts_path(organisation, project, ticket),
           params: { post: { content: 'Test post content' } }, headers: stream_headers
      expect(response).to have_http_status(:ok)
      expect_ranked_row(response.body)
    end

    it 'on update' do
      patch organisation_project_ticket_post_path(organisation, project, ticket, existing_post),
            params: { post: { content: 'Updated content' } }, headers: stream_headers
      expect(response).to have_http_status(:ok)
      expect_ranked_row(response.body)
    end

    it 'on destroy' do
      delete organisation_project_ticket_post_path(organisation, project, ticket, existing_post), headers: stream_headers
      expect(response).to have_http_status(:ok)
      expect_ranked_row(response.body)
    end
  end
  # The ruled short page (D8 of doc/wissen_als_bahn_plan.md, user, 10.09.2026).
  # #768 removed the filler rows the same morning: their cell had lost its
  # colspan and drew a short dash per phantom row down the left edge. The
  # ruling is wanted, the dash was the defect. So a short page is padded to
  # its size with rows that span the WHOLE head, and a full page gets none.
  describe 'the ruled short page' do
    def table_of(body) = Nokogiri::HTML(body).css('#tickets_list_frame table')
    def rows_of(body) = table_of(body).css('tbody tr')
    def ruled_rows_of(body) = rows_of(body).select { |row| row.key?('data-ruled-line') }

    it 'pads a short page to its size with rows that span the whole head' do
      get organisation_project_tickets_path(organisation, project)

      expect(response).to have_http_status(:ok)
      rows = rows_of(response.body)
      ticket_rows = rows.select { |row| row['data-ticket-id'].present? }
      ruled_rows = ruled_rows_of(response.body)

      expect(ticket_rows.size).to eq(1)
      # The page size the controller really reads: the reader's preference
      # (User::PreferenceStore default 20), consulted before any controller default.
      expect(ruled_rows.size).to eq(user.items_per_page_preference - 1)
      expect(rows.size).to eq(ticket_rows.size + ruled_rows.size)

      head_cells = table_of(response.body).css('thead th').size
      expect(ruled_rows.map { |row| row.at_css('td')['colspan'].to_i }.uniq).to eq([head_cells])
      expect(ruled_rows.map { |row| row['aria-hidden'] }).to all(eq('true'))
    end

    it 'rules nothing on a full page' do
      page_size = user.items_per_page_preference
      # Paused for the SETUP only: the suite scans every example from its
      # start, and nineteen ticket creations load the tenant once each, which
      # Prosopite reads as an N+1 of the factory, not of the page. The request
      # below runs scanned; a page that loads something per row still fails here.
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          create_list(:ticket, page_size - 1, project: project, creator: user)
        end
      end

      get organisation_project_tickets_path(organisation, project)

      expect(ruled_rows_of(response.body)).to be_empty
      expect(rows_of(response.body).size).to eq(page_size)
    end
  end
end

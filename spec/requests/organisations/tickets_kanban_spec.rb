# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Tickets Kanban Board', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  let!(:status_attr) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: {
                                           'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                                             { 'value' => 'In Bearbeitung', 'labels' => { 'de' => 'In Bearbeitung' }, 'system_functions' => ['is_in_progress'] },
                                             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
                                           ]
                                         })
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  describe 'GET index with kanban view_mode' do
    let!(:view_config) do
      ViewConfiguration.create!(
        user: user, project: project, organisation: organisation,
        view_type: 'tickets', view_mode: 'kanban',
        table_columns: %w[number title], header_columns: %w[assignees],
        list_columns: { 'cells' => [], 'metadata' => [] }
      )
    end

    let!(:ticket_new) { create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'Neu' }) }
    let!(:ticket_wip) { create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'In Bearbeitung' }) }

    it 'renders kanban board' do
      get organisation_project_tickets_path(organisation, project)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="kanban-board"')
      expect(response.body).to include('kanban-column')
    end

    # The keyboard (doc/kanban_keyboard_plan.md, S2 and S8): every stop of the
    # board renders tabindex -1 and the board's controller puts 0 on its one
    # cursor, so the server never renders a 0 here; the head is a stop with
    # its label on the column; Space is not the card's (it carries, D1); the
    # live line and its texts are in the markup.
    it 'renders every stop for one cursor, the live line and the texts for the keyboard' do
      get organisation_project_tickets_path(organisation, project)
      board = Nokogiri::HTML(response.body).at_css('[data-controller="kanban-board"]')

      cards = board.css('.kanban-card')
      expect(cards.size).to eq(2)
      expect(cards.map { |card| card['tabindex'] }.uniq).to eq(['-1'])
      expect(cards.map { |card| card['data-ticket-number'] }).to all(be_present)
      expect(cards.map { |card| card['data-action'] }.uniq).to eq(['click->list-row#click keydown.enter->list-row#click'])
      expect(board.css('.kanban-column-header').map { |head| head['tabindex'] }.uniq).to eq(['-1'])
      expect(board.css('.kanban-add-ticket').map { |add| add['tabindex'] }.uniq).to eq(['-1'])
      expect(board.css('[tabindex="0"]')).to be_empty
      expect(board.css('.kanban-column').map { |column| column['data-column-label'] }).to include('Neu', 'In Bearbeitung')

      expect(board.at_css('[role="status"][aria-live="polite"][data-kanban-board-target="live"]')).to be_present
      texts = JSON.parse(board['data-kanban-board-texts-value'])
      expect(texts.keys).to contain_exactly('card', 'head', 'picked_up', 'dropped', 'put_back')
      expect(texts['card']).to include('%{number}', '%{column}', '%{position}', '%{count}') # rubocop:disable Style/FormatStringToken
      expect(board['data-action']).to eq('keydown->kanban-board#key')
    end

    it 'falls back to table when no eligible attribute exists' do
      status_attr.destroy
      get organisation_project_tickets_path(organisation, project)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-controller="kanban-board"')
    end

    # Regression: the filter bar (search / ad-hoc filters / search depth) navigates by
    # reloading the 'tickets_list_frame' turbo-frame. In board mode the board must live
    # inside that frame, otherwise frame-targeted navigation is a silent no-op and search
    # appears broken (the URL changes but the board never reloads).
    it 'wraps the board in the tickets_list_frame so the filter bar can reload it' do
      get organisation_project_tickets_path(organisation, project)
      expect(response).to have_http_status(:ok)
      expect(response.body).to match(
        /<turbo-frame[^>]*id="tickets_list_frame".*?data-controller="kanban-board"/m
      )
    end

    it 'answers a tickets_list_frame turbo-frame request with only the board' do
      get organisation_project_tickets_path(organisation, project),
          headers: { 'Turbo-Frame' => 'tickets_list_frame' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="tickets_list_frame"')
      expect(response.body).to include('data-controller="kanban-board"')
      # The frame response must not re-render the page chrome (filter bar) on each keystroke.
      expect(response.body).not_to include('data-controller="filter-bar"')
    end

    it 'applies the search term to the board so a frame reload shows filtered cards' do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, creator: user, title: 'Übersicht umbauen',
                        custom_attributes: { 'status' => 'Neu' })
        create(:ticket, project: project, creator: user, title: 'Komplett anderes Thema',
                        custom_attributes: { 'status' => 'Neu' })
      end

      get organisation_project_tickets_path(organisation, project),
          params: { search: 'Übersicht', search_mode: 'title_only' },
          headers: { 'Turbo-Frame' => 'tickets_list_frame' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Übersicht umbauen')
      expect(response.body).not_to include('Komplett anderes Thema')
    end
  end

  describe 'GET index with table view_mode (default)' do
    it 'renders table view without kanban board' do
      get organisation_project_tickets_path(organisation, project)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-controller="kanban-board"')
    end
  end

  describe 'PATCH update_kanban_attribute' do
    let!(:ticket) { create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'Neu' }) }

    it 'updates ticket attribute with valid value' do
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket),
            params: { attribute_name: 'status', value: 'Erledigt' },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      expect(ticket.reload.get_custom_attribute('status')).to eq('Erledigt')
    end

    it 'returns 422 for invalid attribute name' do
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket),
            params: { attribute_name: 'nonexistent', value: 'Erledigt' }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 for invalid value' do
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket),
            params: { attribute_name: 'status', value: 'Invalid' }
      expect(response).to have_http_status(:unprocessable_content)
    end

    # S8 of doc/kanban_ticket_als_bahn_plan.md: a drop into "Nicht zugeordnet"
    # is a clear, and a clear of a strictly required field is refused in the
    # write path; the JSON carries the code, so the board can say why it put
    # the card back.
    it 'refuses a clear of a strictly required attribute with code required' do
      status_attr.update!(validation_rules: { 'required' => true })
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket),
            params: { attribute_name: 'status', value: nil }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('required')
      expect(ticket.reload.get_custom_attribute('status')).to eq('Neu')
    end

    it 'clears an optional attribute on a drop into the unassigned column' do
      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket),
            params: { attribute_name: 'status', value: nil }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload.get_custom_attribute('status')).to be_nil
    end

    it 'creates activity via Actors::SaveTicket' do
      expect do
        patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, ticket),
              params: { attribute_name: 'status', value: 'Erledigt' },
              headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      end.to(change do
        ActsAsTenant.with_tenant(organisation) { Activity.count }
      end)
    end

    # S0 of doc/kanban_ticket_als_bahn_plan.md (section 4.6). After a drop the
    # action streams the dragged ticket's head into the display frames. The
    # server always sends that stream: it does not know which ticket the
    # browser has open and must not start to. The SELECTOR decides where the
    # head lands. So this does not look for "no head stream"; it takes the
    # selectors out of the response and runs them against rendered markup.
    # Unscoped (`#ticket_display_frame #ticket-header`) the desktop selector
    # found the OTHER ticket's head: open A, drag B, and B's head sat over A's
    # comments and history. The slide-over had that bug; the lane makes the
    # sequence a normal one.
    describe 'the head stream after a drop' do
      let!(:other_ticket) do
        create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'Neu' })
      end

      # The `targets` of every stream in the drop's response whose template
      # carries a ticket head. Two today, one per display frame (desktop and
      # mobile).
      def head_selectors_after_dropping(dropped)
        patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, dropped),
              params: { attribute_name: 'status', value: 'Erledigt' },
              headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
        expect(response).to have_http_status(:ok)
        Nokogiri::HTML.fragment(response.body).css('turbo-stream').filter_map do |stream|
          stream['targets'] if stream.at_css('#ticket-header')
        end
      end

      # The page with a ticket in place renders one display frame around
      # _ticket_display: the shared frame on desktop and mobile with
      # ?viewport=mobile (ViewportSwitchable). The table page renders them with
      # the ticket, and since the lane so does the board, from the same
      # partial (_ticket_lane); the table is what this spec asks. Pinned to
      # exactly one head inside
      # the frame, because a zero below would also pass against a page that
      # shows no head at all.
      def page_showing(shown, viewport:, frame_id:)
        get organisation_project_tickets_path(organisation, project),
            params: { ticket_id: shown.id, viewport: viewport }
        expect(response).to have_http_status(:ok)
        page = Nokogiri::HTML(response.body)
        expect(page.css("##{frame_id} #ticket-header").size).to eq(1)
        page
      end

      def heads_found_by(selectors, page)
        selectors.sum { |selector| page.css(selector).size }
      end

      { 'desktop' => 'ticket_display_frame', 'mobile' => 'ticket_display_frame' }.each do |viewport, frame_id|
        context "on the #{viewport} page" do
          it 'lands on the head of the dragged ticket, once' do
            selectors = head_selectors_after_dropping(ticket)
            page = page_showing(ticket, viewport: viewport, frame_id: frame_id)

            expect(heads_found_by(selectors, page)).to eq(1)
          end

          it 'leaves the head of another open ticket alone' do
            selectors = head_selectors_after_dropping(ticket)
            page = page_showing(other_ticket, viewport: viewport, frame_id: frame_id)

            expect(heads_found_by(selectors, page)).to eq(0)
          end
        end
      end
    end
  end

  describe 'PATCH update_view_mode' do
    it 'switches to kanban mode' do
      patch update_view_mode_organisation_project_view_configuration_path(organisation, project),
            params: { view_mode: 'kanban' }
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))

      ActsAsTenant.with_tenant(organisation) do
        config = ViewConfiguration.for_user_project(user, project, 'tickets')
        expect(config.view_mode).to eq('kanban')
      end
    end

    it 'switches to table mode' do
      patch update_view_mode_organisation_project_view_configuration_path(organisation, project),
            params: { view_mode: 'table' }
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
    end

    it 'ignores invalid view_mode' do
      patch update_view_mode_organisation_project_view_configuration_path(organisation, project),
            params: { view_mode: 'invalid' }
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
    end
  end
end

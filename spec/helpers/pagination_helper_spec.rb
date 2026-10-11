# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PaginationHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  # --- pagination_info_text ---

  describe '#pagination_info_text' do
    before do
      # i18n "von" for the test
      allow(helper).to receive(:t).with('views.shared.pagination.of').and_return('von')
    end

    it 'returns nil for empty results (count=0)' do
      pagy = Pagy.new(count: 0, page: 1, limit: 20)
      expect(helper.pagination_info_text(pagy)).to be_nil
    end

    it 'calculates correctly for page 1 with 20 items per page and 36 total' do
      pagy = Pagy.new(count: 36, page: 1, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('1 – 20 von 36')
    end

    it 'calculates correctly for page 2 with 20 items per page and 36 total' do
      pagy = Pagy.new(count: 36, page: 2, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('21 – 36 von 36')
    end

    it 'calculates correctly for page 1 with 10 items per page and 25 total' do
      pagy = Pagy.new(count: 25, page: 1, limit: 10)
      expect(helper.pagination_info_text(pagy)).to eq('1 – 10 von 25')
    end

    it 'calculates correctly for page 2 with 10 items per page and 25 total' do
      pagy = Pagy.new(count: 25, page: 2, limit: 10)
      expect(helper.pagination_info_text(pagy)).to eq('11 – 20 von 25')
    end

    it 'calculates correctly for last page with partial results' do
      pagy = Pagy.new(count: 25, page: 3, limit: 10)
      expect(helper.pagination_info_text(pagy)).to eq('21 – 25 von 25')
    end

    it 'calculates correctly when all items fit on one page' do
      pagy = Pagy.new(count: 5, page: 1, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('1 – 5 von 5')
    end

    it 'calculates correctly with exactly one item' do
      pagy = Pagy.new(count: 1, page: 1, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('1 – 1 von 1')
    end

    it 'calculates correctly when count equals limit exactly' do
      pagy = Pagy.new(count: 20, page: 1, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('1 – 20 von 20')
    end

    it 'calculates correctly with 50 items per page' do
      pagy = Pagy.new(count: 120, page: 2, limit: 50)
      expect(helper.pagination_info_text(pagy)).to eq('51 – 100 von 120')
    end

    it 'calculates correctly for last page with 50 items per page' do
      pagy = Pagy.new(count: 120, page: 3, limit: 50)
      expect(helper.pagination_info_text(pagy)).to eq('101 – 120 von 120')
    end

    # Exact reproduction test for the reported bug:
    # Page 5, 20 items per page, 291 total → expected "81 – 100 von 291"
    it 'calculates correctly for page 5 with 20 items per page and 291 total (reported bug scenario)' do
      pagy = Pagy.new(count: 291, page: 5, limit: 20)

      # Verify Pagy-internal values
      expect(pagy.page).to eq(5)
      expect(pagy.limit).to eq(20)
      expect(pagy.count).to eq(291)
      expect(pagy.pages).to eq(15) # ceil(291/20) = 15
      expect(pagy.from).to eq(81)  # (5-1)*20 + 1 = 81
      expect(pagy.to).to eq(100)   # min(5*20, 291) = 100

      expect(helper.pagination_info_text(pagy)).to eq('81 – 100 von 291')
    end

    it 'calculates correctly for page 1 with 20 items per page and 291 total' do
      pagy = Pagy.new(count: 291, page: 1, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('1 – 20 von 291')
    end

    it 'calculates correctly for last page with 20 items per page and 291 total' do
      pagy = Pagy.new(count: 291, page: 15, limit: 20)
      expect(helper.pagination_info_text(pagy)).to eq('281 – 291 von 291')
    end

    # Test that from/to are consistent with page/limit (no contradiction possible)
    it 'ensures from and to are always consistent with page and limit' do
      [
        { count: 291, page: 5, limit: 20, expected_from: 81, expected_to: 100 },
        { count: 100, page: 3, limit: 10, expected_from: 21, expected_to: 30 },
        { count: 55, page: 3, limit: 20, expected_from: 41, expected_to: 55 },
        { count: 1, page: 1, limit: 20, expected_from: 1, expected_to: 1 }
      ].each do |scenario|
        pagy = Pagy.new(count: scenario[:count], page: scenario[:page], limit: scenario[:limit])
        expect(pagy.from).to eq(scenario[:expected_from]),
                             "Expected from=#{scenario[:expected_from]} for page=#{scenario[:page]} limit=#{scenario[:limit]}, got #{pagy.from}"
        expect(pagy.to).to eq(scenario[:expected_to]),
                           "Expected to=#{scenario[:expected_to]} for page=#{scenario[:page]} limit=#{scenario[:limit]} count=#{scenario[:count]}, got #{pagy.to}"
      end
    end
  end

  # --- pagination_frame_id ---

  describe '#pagination_frame_id' do
    it 'returns custom frame_id when provided' do
      allow(helper).to receive(:controller_name).and_return('tickets')
      expect(helper.pagination_frame_id(frame_id: 'custom_frame')).to eq('custom_frame')
    end

    it 'returns tickets_list_frame for tickets controller' do
      allow(helper).to receive(:controller_name).and_return('tickets')
      expect(helper.pagination_frame_id).to eq('tickets_list_frame')
    end

    it 'returns time_sessions_list_frame for time_sessions controller' do
      allow(helper).to receive(:controller_name).and_return('time_sessions')
      expect(helper.pagination_frame_id).to eq('time_sessions_list_frame')
    end

    it 'returns knowledge_results for knowledge controller' do
      allow(helper).to receive(:controller_name).and_return('knowledge')
      expect(helper.pagination_frame_id).to eq('knowledge_results')
    end

    it 'falls back to _top for the frame-less notes/documents controllers (M6: kein eigenes Listing mehr)' do
      allow(helper).to receive(:controller_name).and_return('notes')
      expect(helper.pagination_frame_id).to eq('_top')
    end

    it 'returns smart-folders-list for smart_folders controller' do
      allow(helper).to receive(:controller_name).and_return('smart_folders')
      expect(helper.pagination_frame_id).to eq('smart-folders-list')
    end

    it 'returns _top for unknown controllers' do
      allow(helper).to receive(:controller_name).and_return('unknown')
      expect(helper.pagination_frame_id).to eq('_top')
    end

    it 'ignores blank frame_id and falls back to controller' do
      allow(helper).to receive(:controller_name).and_return('tickets')
      expect(helper.pagination_frame_id(frame_id: '')).to eq('tickets_list_frame')
    end
  end

  # --- pagination_items_frame ---

  describe '#pagination_items_frame' do
    context 'for tickets controller' do
      before { allow(helper).to receive(:controller_name).and_return('tickets') }

      it 'returns tickets_list_frame when selected_object present' do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        allow(helper).to receive(:action_name).and_return('index')
        result = helper.pagination_items_frame(frame_id: '_top', selected_object: 'some-ticket')
        expect(result).to eq('tickets_list_frame')
      end

      it 'returns tickets_list_frame when ticket_id in params' do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new(ticket_id: 'abc-123'))
        allow(helper).to receive(:action_name).and_return('index')
        result = helper.pagination_items_frame(frame_id: '_top', selected_object: nil)
        expect(result).to eq('tickets_list_frame')
      end

      it 'returns tickets_list_frame when on show action (detail view)' do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        allow(helper).to receive(:action_name).and_return('show')
        result = helper.pagination_items_frame(frame_id: '_top', selected_object: nil)
        expect(result).to eq('tickets_list_frame')
      end

      it 'returns _top when no ticket selected on index' do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        allow(helper).to receive(:action_name).and_return('index')
        result = helper.pagination_items_frame(frame_id: 'tickets_list_frame', selected_object: nil)
        expect(result).to eq('_top')
      end
    end

    context 'for non-tickets controller' do
      before { allow(helper).to receive(:controller_name).and_return('notes') }

      it 'returns the given frame_id' do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        result = helper.pagination_items_frame(frame_id: 'notes_results', selected_object: nil)
        expect(result).to eq('notes_results')
      end
    end
  end

  # --- pagination_page_url ---

  describe '#pagination_page_url' do
    let(:pagy) { instance_double('Pagy', prev: 1, next: 3, page: 2, pages: 5) }
    let(:mock_request) do
      instance_double('ActionDispatch::Request',
                      protocol: 'http://',
                      host_with_port: 'localhost:3000',
                      path: '/org/abc/projects/def/tickets',
                      path_info: '/org/abc/projects/def/tickets',
                      query_parameters: {})
    end

    before do
      allow(helper).to receive(:request).and_return(mock_request)
      allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
    end

    it 'returns # for nil page' do
      allow(helper).to receive(:controller_name).and_return('tickets')
      expect(helper.pagination_page_url(pagy, nil)).to eq('#')
    end

    context 'for tickets controller' do
      before { allow(helper).to receive(:controller_name).and_return('tickets') }

      it 'generates absolute URL with org/project from params' do
        allow(helper).to receive(:params).and_return(
          ActionController::Parameters.new(organisation_id: 'org-1', project_id: 'proj-1')
        )
        url = helper.pagination_page_url(pagy, 3, organisation: organisation, project: project)
        expect(url).to start_with('http://localhost:3000/org/')
        expect(url).to include('/tickets?')
        expect(url).to include('page=3')
      end

      it 'includes smart_folder_id in query params' do
        allow(helper).to receive(:params).and_return(
          ActionController::Parameters.new(organisation_id: 'org-1', project_id: 'proj-1')
        )
        url = helper.pagination_page_url(pagy, 2, organisation: organisation, project: project, smart_folder_id: 'sf-123')
        expect(url).to include('smart_folder_id=sf-123')
      end

      it 'removes project_id from sort_params for tickets' do
        allow(helper).to receive(:params).and_return(
          ActionController::Parameters.new(organisation_id: 'org-1', project_id: 'proj-1')
        )
        url = helper.pagination_page_url(pagy, 2, organisation: organisation, project: project,
                                                  sort_params: { column: 'title', direction: 'asc', project_id: 'proj-1' })
        expect(url).not_to include('project_id=')
        expect(url).to include('column=title')
      end
    end

    context 'for notes controller' do
      before { allow(helper).to receive(:controller_name).and_return('notes') }

      it 'generates relative URL via route helper' do
        allow(helper).to receive(:organisation_project_notes_path)
          .with(organisation, project).and_return('/org/abc/projects/def/notes')
        url = helper.pagination_page_url(pagy, 2, organisation: organisation, project: project)
        expect(url).to include('/notes?')
        expect(url).to include('page=2')
      end
    end

    context 'for unknown controller' do
      before { allow(helper).to receive(:controller_name).and_return('unknown') }

      it 'falls back to request base path' do
        url = helper.pagination_page_url(pagy, 2)
        expect(url).to include('/org/abc/projects/def/tickets?')
        expect(url).to include('page=2')
      end
    end
  end

  # --- pagination_items_url ---

  describe '#pagination_items_url' do
    let(:mock_request) do
      instance_double('ActionDispatch::Request',
                      protocol: 'http://',
                      host_with_port: 'localhost:3000',
                      path: '/org/abc/projects/def/notes',
                      path_info: '/org/abc/projects/def/notes',
                      query_parameters: {})
    end

    before do
      allow(helper).to receive(:request).and_return(mock_request)
      allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
      allow(helper).to receive(:controller_name).and_return('notes')
      allow(helper).to receive(:organisation_project_notes_path)
        .with(organisation, project).and_return('/org/abc/projects/def/notes')
    end

    it 'includes items parameter' do
      url = helper.pagination_items_url(50, organisation: organisation, project: project)
      expect(url).to include('items=50')
    end

    it 'does not include page parameter' do
      allow(helper).to receive(:params).and_return(ActionController::Parameters.new(items: '20'))
      url = helper.pagination_items_url(50, organisation: organisation, project: project)
      expect(url).not_to include('page=')
    end

    it 'preserves search params' do
      allow(helper).to receive(:request).and_return(
        instance_double('ActionDispatch::Request',
                        protocol: 'http://',
                        host_with_port: 'localhost:3000',
                        path: '/org/abc/projects/def/notes',
                        path_info: '/org/abc/projects/def/notes',
                        query_parameters: { 'search' => 'test query', 'search_mode' => 'full' })
      )
      url = helper.pagination_items_url(20, organisation: organisation, project: project)
      expect(url).to include('search=test')
      expect(url).to include('search_mode=full')
    end
  end
end

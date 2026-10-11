# frozen_string_literal: true

require 'rails_helper'

# Behaviour guards for the SmartFolder filtering in the ObjectListController concern,
# exercised via tickets#index (the canonical user of the concern). Pins the
# filter paths (relation/array/wrong type/missing folder) and the
# auto-pagination BEFORE deduplicating the SmartFolder logic that was copied twice.
# The stub seam is SmartFolderService#fetch_results — exists before and after the refactor.
RSpec.describe 'Tickets index SmartFolder filter', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  # 3 folder tickets, plus 1 older + 1 newer ticket outside the folder each —
  # so the middle folder ticket stays position-stable (pos. 2 filtered,
  # pos. 3 unfiltered) regardless of the default sort direction.
  let!(:ticket_old) { create_ticket('Älter außerhalb', 5.days.ago) }
  let!(:folder_ticket_one) { create_ticket('Folder Eins', 4.days.ago) }
  let!(:folder_ticket_two) { create_ticket('Folder Zwei', 3.days.ago) }
  let!(:folder_ticket_three) { create_ticket('Folder Drei', 2.days.ago) }
  let!(:ticket_new) { create_ticket('Neuer außerhalb', 1.day.ago) }

  let(:folder_tickets) { [folder_ticket_one, folder_ticket_two, folder_ticket_three] }
  let(:smart_folder) do
    ActsAsTenant.current_tenant = organisation
    create(:smart_folder, organisation: organisation, user: user, target_object_type: 'Ticket', name: 'Mein Filter')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  def create_ticket(title, created_at)
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user, title: title, created_at: created_at)
  end

  def stub_folder_results(items)
    allow_any_instance_of(SmartFolderService).to receive(:fetch_results).and_return({ items: items })
  end

  def get_index(extra_params = {})
    get organisation_project_tickets_path(organisation, project), params: extra_params
  end

  # Ticket titles also appear outside the result list in the page HTML
  # (e.g. navigation/modal contexts) — so check the rows in the list frame
  # specifically instead of the whole body.
  def listed_ticket_ids
    frame = Nokogiri::HTML(response.body).at_css('turbo-frame#tickets_list_frame')
    expect(frame).to be_present
    frame.css('[data-ticket-id]').map { |node| node['data-ticket-id'] }.uniq
  end

  context 'with a folder returning an ActiveRecord relation' do
    before { stub_folder_results(Ticket.where(id: folder_tickets.map(&:id))) }

    it 'shows only folder tickets of the current project' do
      get_index(smart_folder_id: smart_folder.id)

      expect(response).to have_http_status(:ok)
      expect(listed_ticket_ids).to match_array(folder_tickets.map(&:id))
    end
  end

  context 'with a folder returning an array' do
    let(:foreign_project_ticket) do
      ActsAsTenant.current_tenant = organisation
      foreign_project = create(:project, organisation: organisation)
      create(:ticket, project: foreign_project, creator: user, title: 'Fremdprojekt-Ticket')
    end

    before { stub_folder_results([folder_ticket_one, foreign_project_ticket]) }

    it 'keeps only items of the current project' do
      get_index(smart_folder_id: smart_folder.id)

      expect(response).to have_http_status(:ok)
      expect(listed_ticket_ids).to contain_exactly(folder_ticket_one.id)
    end
  end

  context 'with a folder configured for another object type' do
    let(:smart_folder) do
      ActsAsTenant.current_tenant = organisation
      create(:smart_folder, organisation: organisation, user: user, target_object_type: 'Document', name: 'Doc Filter')
    end

    it 'ignores the folder and shows the unfiltered list' do
      expect_any_instance_of(SmartFolderService).not_to receive(:fetch_results)

      get_index(smart_folder_id: smart_folder.id)

      expect(response).to have_http_status(:ok)
      expect(listed_ticket_ids).to match_array(
        [ticket_old, *folder_tickets, ticket_new].map(&:id)
      )
    end
  end

  context 'with an unknown smart_folder_id' do
    it 'shows the unfiltered list with the not-found notice' do
      get_index(smart_folder_id: SecureRandom.uuid)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(t_smart_folder_not_found)
      expect(listed_ticket_ids).to match_array(
        [ticket_old, *folder_tickets, ticket_new].map(&:id)
      )
    end
  end

  context 'auto-pagination for a selected ticket (calculate_and_redirect_to_object_page)' do
    before { stub_folder_results(Ticket.where(id: folder_tickets.map(&:id))) }

    it 'computes the page within the FILTERED list and keeps the folder param' do
      # items=1: page == position. When filtered, the middle folder ticket is at
      # position 2 (instead of 3 unfiltered) — regardless of asc or desc sorting.
      get_index(smart_folder_id: smart_folder.id, ticket_id: folder_ticket_two.id, items: 1)

      expect(response).to have_http_status(:redirect)
      redirect_uri = URI.parse(response.location)
      query = Rack::Utils.parse_query(redirect_uri.query)
      expect(query['page']).to eq('2')
      expect(query['smart_folder_id']).to eq(smart_folder.id)
      expect(query['ticket_id']).to eq(folder_ticket_two.id)
    end

    it 'falls back to the unfiltered position when the folder does not exist' do
      get_index(smart_folder_id: SecureRandom.uuid, ticket_id: folder_ticket_two.id, items: 1)

      expect(response).to have_http_status(:redirect)
      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      expect(query['page']).to eq('3')
    end

    it 'does not redirect when the selected ticket is already on page 1' do
      get_index(smart_folder_id: smart_folder.id, ticket_id: page_one_folder_ticket.id, items: 1)

      expect(response).to have_http_status(:ok)
    end
  end

  private

  def t_smart_folder_not_found
    I18n.t('smart_folders.not_found', default: 'Der angegebene Ticket Filter wurde nicht gefunden.')
  end

  # First folder ticket in the actual sort order (direction-independent):
  # with created_at asc it is folder_ticket_one, with desc folder_ticket_three —
  # we take the one whose position is 1 by checking both candidates.
  def page_one_folder_ticket
    get_index(smart_folder_id: smart_folder.id, ticket_id: folder_ticket_one.id, items: 1)
    response.status == 200 ? folder_ticket_one : folder_ticket_three
  end
end

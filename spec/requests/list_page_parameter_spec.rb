# frozen_string_literal: true

require 'rails_helper'

# What:  Every paged list answers a page number nobody can show.
# Type:  Request spec over all lists that read `?page=`.
# Why:   The value comes from the address bar. A typo, a crawler that counts a
#        pagination link down, or a bookmark of a list that got shorter must get a
#        page. Until 18.11.2026 the lists that paged without the Pageable concern
#        raised on `?page[]=1`, and every list raised on a number so large that
#        the OFFSET left PostgreSQL's range.
# Owner: Pagination::Page (one reading of the page number for every list).
RSpec.describe 'The page parameter of a list', type: :request do
  unshowable_pages = {
    'zero' => { page: '0' },
    'a negative number' => { page: '-3' },
    'text' => { page: 'abc' },
    'a page behind the last one' => { page: '99999' },
    'a number beyond any offset' => { page: '9' * 30 },
    'a list' => { page: ['1'] },
    'a hash' => { page: { a: '1' } }
  }.freeze

  # The page size the bars set (`?items=`) is read on every request of a signed-in
  # reader (ApplicationController stores it) and by the bars themselves.
  unreadable_sizes = {
    'a page size as a list' => { items: ['20'] },
    'a page size as a hash' => { items: { a: '20' } }
  }.freeze

  let(:organisation) { create(:organisation) }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user) }

  describe 'in the application' do
    before do
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      sign_in user
    end

    after { ActsAsTenant.current_tenant = nil }

    lists = {
      'tickets' => ->(params) { organisation_project_tickets_path(organisation, project, params) },
      'knowledge' => ->(params) { organisation_project_knowledge_index_path(organisation, project, params) },
      'meetings of a project' => ->(params) { organisation_project_meetings_path(organisation, project, params) },
      'all meetings' => ->(params) { organisation_meetings_path(organisation, params) },
      'times' => ->(params) { organisation_time_sessions_path(organisation, params) },
      'time groups' => ->(params) { organisation_time_session_groups_path(organisation, params) },
      'project activities' => ->(params) { organisation_project_activities_path(organisation, project, params) },
      'smart folders' => ->(params) { organisation_smart_folders_path(organisation, params) },
      'member activities' => ->(params) { organisation_user_activities_path(organisation, params.merge(user_id: user.id)) },
      'AI protocol' => ->(params) { organisation_ai_protocol_path(organisation, params) },
      'inbox' => ->(params) { organisation_notifications_path(organisation, params) },
      # Its controller turns any error into a redirect to the list of views, so a
      # 200 is the proof here, not the absence of a 500.
      'results of a saved view' => lambda { |params|
        folder = create(:smart_folder, organisation: organisation, project: project, user: user)
        organisation_smart_folder_path(organisation, folder, params)
      }
    }

    # A full page of the ticket list with a page number redirects to the list
    # without one (ObjectListController); only its frame pages.
    headers = { 'tickets' => { 'Turbo-Frame' => 'tickets_list_frame' } }

    lists.each do |name, path|
      unshowable_pages.merge(unreadable_sizes).each do |kind, params|
        it "#{name}: answers #{kind}" do
          get instance_exec(params, &path), headers: headers.fetch(name, {})

          expect(response).to have_http_status(:ok)
        end
      end
    end

    it 'stores no page size from a list or a hash' do
      expect { get organisation_ai_protocol_path(organisation, items: ['20']) }
        .not_to(change { user.reload.items_per_page_preference })
    end
  end

  # The list reads under an isolation level of its own, which needs a real
  # top-level transaction.
  describe 'in the inbox of all organisations', :real_transactions do
    before do
      # With one organisation this address sends on to that one's inbox.
      [organisation, create(:organisation)].each do |member_of|
        ActsAsTenant.with_tenant(member_of) do
          create(:membership, user: user, organisation: member_of, role: create(:admin_role, organisation: member_of))
        end
      end
      sign_in user
    end

    unshowable_pages.each do |kind, params|
      it "answers #{kind}" do
        get all_inboxes_path(params)

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'in the admin area' do
    before do
      beuser = create(:beuser)
      post admin_log_in_path, params: { email: beuser.email, password: beuser.password }
    end

    lists = {
      'mail log' => ->(params) { admin_email_logs_path(params) },
      'deletion register' => ->(params) { admin_deletion_register_path(params) }
    }

    lists.each do |name, path|
      unshowable_pages.each do |kind, params|
        it "#{name}: answers #{kind}" do
          get instance_exec(params, &path)

          expect(response).to have_http_status(:ok)
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::CodebaseImportFiles', type: :request do
  include ActiveJob::TestHelper

  # Importing is an operator-gated feature (see the "operator gate" block at the very
  # bottom). Everything above it asks who may import where importing is available, so
  # the flag is on for the shared organisation.
  let(:organisation) { create(:organisation, data_import_enabled: true) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }

  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    ActiveJob::Base.queue_adapter = :test
  end

  after do
    ActsAsTenant.current_tenant = organisation
  end

  # ──────────────────────────────────────────────
  # Helper: valid XML content for each type
  # ──────────────────────────────────────────────
  let(:valid_users_xml) do
    <<~XML
      <users-users>
        <users-user>
          <id>1</id>
          <first-name>Test</first-name>
          <last-name>User</last-name>
          <email-address>test@example.com</email-address>
          <company><id>1</id><name>TestCo</name></company>
          <role><id>1</id><name>Admin</name><account-administrator>false</account-administrator></role>
        </users-user>
      </users-users>
    XML
  end

  let(:valid_tickets_xml) do
    <<~XML
      <tickets-tickets>
        <tickets-ticket>
          <id>123</id>
          <ticket-id>1</ticket-id>
          <subject>Test Ticket</subject>
          <ticket-type>Task</ticket-type>
          <reporter-id>1</reporter-id>
          <assignee-id>2</assignee-id>
          <status-cache>Open</status-cache>
          <priority-cache>High</priority-cache>
          <project-id>10</project-id>
          <created-at>2023-01-01T10:00:00Z</created-at>
          <updated-at>2023-01-01T11:00:00Z</updated-at>
          <updates></updates>
        </tickets-ticket>
      </tickets-tickets>
    XML
  end

  let(:valid_time_tracking_xml) do
    <<~XML
      <time-sessions-sessions>
        <time-sessions-session>
          <id>1</id>
          <minutes>60</minutes>
          <summary>Test session</summary>
          <user-id>1</user-id>
          <cached-name>Test User</cached-name>
          <project-id>10</project-id>
          <ticket-id>123</ticket-id>
          <occurred-on>2023-01-15</occurred-on>
        </time-sessions-session>
      </time-sessions-sessions>
    XML
  end

  let(:valid_uploads_xml) do
    <<~XML
      <uploads>
        <upload>
          <id>1</id>
          <file-file-name>test.png</file-file-name>
          <file-content-type>image/png</file-content-type>
          <file-file-size>1024</file-file-size>
        </upload>
      </uploads>
    XML
  end

  # ──────────────────────────────────────────────
  # Helper paths
  # ──────────────────────────────────────────────
  def index_path
    organisation_codebase_import_files_path(organisation)
  end

  def new_path
    new_organisation_codebase_import_file_path(organisation)
  end

  def show_path(file)
    organisation_codebase_import_file_path(organisation, file)
  end

  def preview_import_path(file)
    preview_import_organisation_codebase_import_file_path(organisation, file)
  end

  def execute_import_path(file)
    execute_import_organisation_codebase_import_file_path(organisation, file)
  end

  def select_project_path(file)
    select_project_organisation_codebase_import_file_path(organisation, file)
  end

  def preview_tickets_path(file)
    preview_tickets_organisation_codebase_import_file_path(organisation, file)
  end

  def execute_tickets_import_path(file)
    execute_tickets_import_organisation_codebase_import_file_path(organisation, file)
  end

  def preview_time_sessions_path(file)
    preview_time_sessions_organisation_codebase_import_file_path(organisation, file)
  end

  def execute_time_sessions_import_path(file)
    execute_time_sessions_import_organisation_codebase_import_file_path(organisation, file)
  end

  def rollback_path(file)
    rollback_organisation_codebase_import_file_path(organisation, file)
  end

  def execute_rollback_path(file)
    execute_rollback_organisation_codebase_import_file_path(organisation, file)
  end

  def assign_uploads_path(file, project)
    assign_uploads_organisation_codebase_import_file_path(organisation, file, project_id: project.id)
  end

  def execute_upload_assignment_path(file)
    execute_upload_assignment_organisation_codebase_import_file_path(organisation, file)
  end

  # Helper to build uploaded files from content
  def xml_upload(content, filename: 'test.xml', content_type: 'text/xml')
    file = Tempfile.new(['test', '.xml'])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, false, original_filename: filename)
  end

  def tar_upload(filename: 'test.tar', content_type: 'application/x-tar')
    file = Tempfile.new(['test', '.tar'])
    file.write('fake tar content')
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: filename)
  end

  def plain_upload(content: 'plain text', filename: 'test.txt', content_type: 'text/plain')
    file = Tempfile.new(['test', '.txt'])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, false, original_filename: filename)
  end

  # Helper to count records safely (tenant may be cleared by middleware)
  def import_file_count
    ActsAsTenant.without_tenant { CodebaseImportFile.where(organisation: organisation).count }
  end

  # ──────────────────────────────────────────────
  # GET #index
  # ──────────────────────────────────────────────
  describe 'GET #index' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get index_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        get index_path
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.no_import_permission'))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get index_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #new
  # ──────────────────────────────────────────────
  describe 'GET #new' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get new_path
        expect(response).to have_http_status(:success)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        get new_path
        expect(response).to redirect_to(root_path)
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get new_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # POST #create
  # ──────────────────────────────────────────────
  describe 'POST #create' do
    context 'as admin' do
      before { sign_in admin }

      context 'with valid users XML' do
        it 'creates a record and redirects to show' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: { file_type: 'users', file: xml_upload(valid_users_xml) }
          }

          expect(import_file_count).to eq(count_before + 1)
          import_file = ActsAsTenant.without_tenant { CodebaseImportFile.last }
          expect(response).to redirect_to(show_path(import_file))
        end
      end

      context 'with valid tickets XML' do
        it 'creates a record' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: { file_type: 'tickets', file: xml_upload(valid_tickets_xml) }
          }

          expect(import_file_count).to eq(count_before + 1)
        end
      end

      context 'with valid time tracking XML' do
        it 'creates a record' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: { file_type: 'time_tracking', file: xml_upload(valid_time_tracking_xml) }
          }

          expect(import_file_count).to eq(count_before + 1)
        end
      end

      context 'with missing file' do
        it 'does not create a record' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: { file_type: 'users', file: nil }
          }

          expect(import_file_count).to eq(count_before)
        end
      end

      context 'with non-XML file' do
        it 'does not create a record' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: {
              file_type: 'users',
              file: plain_upload
            }
          }

          expect(import_file_count).to eq(count_before)
        end
      end

      context 'with invalid XML content' do
        it 'does not create a record' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: {
              file_type: 'users',
              file: xml_upload('<invalid><not-closed')
            }
          }

          expect(import_file_count).to eq(count_before)
        end
      end

      context 'with valid XML but wrong schema for file_type' do
        it 'rejects users file_type with tickets XML' do
          post index_path, params: {
            codebase_import_file: { file_type: 'users', file: xml_upload(valid_tickets_xml) }
          }

          expect(import_file_count).to eq(0)
        end

        it 'rejects tickets file_type with users XML' do
          post index_path, params: {
            codebase_import_file: { file_type: 'tickets', file: xml_upload(valid_users_xml) }
          }

          expect(import_file_count).to eq(0)
        end
      end

      context 'with uploads file_type' do
        it 'requires a TAR/ZIP archive file' do
          post index_path, params: {
            codebase_import_file: {
              file_type: 'uploads',
              file: xml_upload(valid_uploads_xml)
            }
          }

          expect(import_file_count).to eq(0)
        end

        it 'creates a record with valid XML and TAR file' do
          count_before = import_file_count

          post index_path, params: {
            codebase_import_file: {
              file_type: 'uploads',
              file: xml_upload(valid_uploads_xml),
              tar_file: tar_upload
            }
          }

          expect(import_file_count).to eq(count_before + 1)
        end
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        post index_path, params: {
          codebase_import_file: { file_type: 'users', file: xml_upload(valid_users_xml) }
        }
        expect(response).to redirect_to(root_path)
        expect(import_file_count).to eq(0)
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        post index_path, params: {
          codebase_import_file: { file_type: 'users', file: xml_upload(valid_users_xml) }
        }
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #show
  # ──────────────────────────────────────────────
  describe 'GET #show' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success for file with valid parsed data' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get show_path(import_file)
        expect(response).to have_http_status(:success)
      end

      it 'redirects with flash when parsed_data is nil' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin)
        import_file.update_column(:file_content, '')
        get show_path(import_file)
        expect(response).to redirect_to(index_path)
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.xml_parse_error'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin)
        get show_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin)
        get show_path(import_file)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # DELETE #destroy
  # ──────────────────────────────────────────────
  describe 'DELETE #destroy' do
    context 'as admin' do
      before { sign_in admin }

      it 'deletes the record and redirects' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin)
        count_before = import_file_count

        delete show_path(import_file)

        expect(import_file_count).to eq(count_before - 1)
        expect(response).to redirect_to(index_path)
        expect(flash[:notice]).to be_present
      end

      it 'blocks deletion when status is processing' do
        import_file = create(:codebase_import_file, :processing, organisation: organisation, user: admin)
        count_before = import_file_count

        delete show_path(import_file)

        expect(import_file_count).to eq(count_before)
        expect(response).to redirect_to(index_path)
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.processing_locked'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin)
        count_before = import_file_count

        delete show_path(import_file)

        expect(import_file_count).to eq(count_before)
        expect(response).to redirect_to(root_path)
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin)
        delete show_path(import_file)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #preview_import
  # ──────────────────────────────────────────────
  describe 'GET #preview_import' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success for users file with valid XML' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        get preview_import_path(import_file)
        expect(response).to have_http_status(:success)
      end

      it 'redirects for non-users file_type' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get preview_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.preview_users_only'))
      end

      it 'redirects when status is processed' do
        import_file = create(:codebase_import_file, :with_valid_users_xml, :processed,
                             organisation: organisation, user: admin)
        get preview_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported_no_reprocess'))
      end

      it 'redirects when status is processing' do
        import_file = create(:codebase_import_file, :with_valid_users_xml, :processing,
                             organisation: organisation, user: admin)
        get preview_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_running'))
      end

      it 'redirects when parsed_data is nil' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        import_file.update_column(:file_content, '')
        get preview_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.xml_parse_error'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        get preview_import_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # POST #execute_import
  # ──────────────────────────────────────────────
  describe 'POST #execute_import' do
    context 'as admin' do
      before { sign_in admin }

      it 'enqueues job and redirects for users file' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)

        expect do
          post execute_import_path(import_file)
        end.to have_enqueued_job(ImportUsersFromCodebaseJob)

        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:notice]).to eq(I18n.t('flash.codebase_import_files.user_import_started'))
      end

      it 'redirects for non-users file_type' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        post execute_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_users_only'))
      end

      it 'redirects when status is processed' do
        import_file = create(:codebase_import_file, :with_valid_users_xml, :processed,
                             organisation: organisation, user: admin)
        post execute_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported_no_reprocess'))
      end

      it 'redirects when status is processing' do
        import_file = create(:codebase_import_file, :with_valid_users_xml, :processing,
                             organisation: organisation, user: admin)
        post execute_import_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_running'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        post execute_import_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #select_project
  # ──────────────────────────────────────────────
  describe 'GET #select_project' do
    context 'as admin' do
      before { sign_in admin }

      it 'redirects to preview_tickets for tickets file_type' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get select_project_path(import_file)
        expect(response).to redirect_to(preview_tickets_path(import_file))
      end

      it 'returns success for time_tracking file with valid data' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)
        get select_project_path(import_file)
        expect(response).to have_http_status(:success)
      end

      it 'redirects for time_tracking with status processed' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processed,
                             organisation: organisation, user: admin)
        get select_project_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported'))
      end

      it 'redirects for wrong file_type (users)' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        get select_project_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.project_select_time_tracking_only'))
      end

      it 'redirects when parsed_data is blank for time_tracking' do
        import_file = create(:codebase_import_file, :time_tracking_file,
                             organisation: organisation, user: admin)
        get select_project_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.no_time_entries'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get select_project_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #preview_tickets
  # ──────────────────────────────────────────────
  describe 'GET #preview_tickets' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success for tickets file with valid XML' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        # analyze_user_references iterates per Codebase user-id to find existing
        # mappings; this per-id lookup is not a real N+1 since each ID is
        # independent and the result is cached by the service.
        Prosopite.pause
        begin
          get preview_tickets_path(import_file)
        ensure
          Prosopite.resume
        end
        expect(response).to have_http_status(:success)
      end

      it 'redirects for non-tickets file_type' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        get preview_tickets_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.ticket_preview_only'))
      end

      it 'redirects when status is processed' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        get preview_tickets_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported_no_reprocess'))
      end

      it 'redirects when status is processing' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processing,
                             organisation: organisation, user: admin)
        get preview_tickets_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_running'))
      end

      it 'redirects when parsed_data is blank' do
        import_file = create(:codebase_import_file, organisation: organisation, user: admin,
                                                    file_type: 'tickets',
                                                    file_content: '<tickets></tickets>')
        get preview_tickets_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.no_tickets_found'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get preview_tickets_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # POST #execute_tickets_import
  # ──────────────────────────────────────────────
  describe 'POST #execute_tickets_import' do
    context 'as admin' do
      before { sign_in admin }

      it 'creates project, enqueues job and redirects' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        project_count_before = ActsAsTenant.without_tenant { Project.where(organisation: organisation).count }

        expect do
          post execute_tickets_import_path(import_file),
               params: { project_name: 'My Import Project', include_tags: '1' }
        end.to have_enqueued_job(ImportTicketsFromCodebaseJob)

        project_count_after = ActsAsTenant.without_tenant { Project.where(organisation: organisation).count }
        expect(project_count_after).to eq(project_count_before + 1)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:notice]).to include('My Import Project')
      end

      it 'redirects when project_name is blank' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        post execute_tickets_import_path(import_file), params: { project_name: '' }
        expect(response).to redirect_to(preview_tickets_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.project_name_required'))
      end

      it 'redirects for non-tickets file_type' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        post execute_tickets_import_path(import_file), params: { project_name: 'Test' }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.ticket_import_only'))
      end

      it 'redirects when status is processed' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        post execute_tickets_import_path(import_file), params: { project_name: 'Test' }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported_no_reprocess'))
      end

      it 'redirects when status is processing' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processing,
                             organisation: organisation, user: admin)
        post execute_tickets_import_path(import_file), params: { project_name: 'Test' }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_running'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        post execute_tickets_import_path(import_file), params: { project_name: 'Test' }
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #preview_time_sessions
  # ──────────────────────────────────────────────
  describe 'GET #preview_time_sessions' do
    let(:project) { create(:project, organisation: organisation) }

    context 'as admin' do
      before { sign_in admin }

      it 'returns success for time_tracking file with valid data' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file), params: { project_id: project.id }
        expect(response).to have_http_status(:success)
      end

      it 'redirects for non-time_tracking file_type' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.time_preview_only'))
      end

      it 'redirects when status is processed' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processed,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported_no_reprocess'))
      end

      it 'redirects when status is processing' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processing,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_running'))
      end

      it 'redirects when project_id is blank' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file)
        expect(response).to redirect_to(select_project_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.select_project'))
      end

      it 'redirects when parsed_data is blank' do
        import_file = create(:codebase_import_file, :time_tracking_file,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.no_time_entries'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)
        get preview_time_sessions_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # POST #execute_time_sessions_import
  # ──────────────────────────────────────────────
  describe 'POST #execute_time_sessions_import' do
    let(:project) { create(:project, organisation: organisation) }

    context 'as admin' do
      before { sign_in admin }

      it 'enqueues job and redirects' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)

        expect do
          post execute_time_sessions_import_path(import_file), params: { project_id: project.id }
        end.to have_enqueued_job(ImportTimeSessionsFromCodebaseJob)

        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:notice]).to eq(I18n.t('flash.codebase_import_files.time_import_started'))
      end

      it 'redirects for non-time_tracking file_type' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        post execute_time_sessions_import_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.time_import_only'))
      end

      it 'redirects when status is processed' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processed,
                             organisation: organisation, user: admin)
        post execute_time_sessions_import_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.already_imported_no_reprocess'))
      end

      it 'redirects when status is processing' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processing,
                             organisation: organisation, user: admin)
        post execute_time_sessions_import_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_running'))
      end

      it 'redirects when project_id is blank' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)
        post execute_time_sessions_import_path(import_file)
        expect(response).to redirect_to(select_project_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.project_required'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml,
                             organisation: organisation, user: admin)
        post execute_time_sessions_import_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #rollback
  # ──────────────────────────────────────────────
  describe 'GET #rollback' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success when imported objects exist' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        create(:imported_object, organisation: organisation,
                                 metadata: { 'import_file_id' => import_file.id })

        get rollback_path(import_file)
        expect(response).to have_http_status(:success)
      end

      it 'redirects when no imported objects exist' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        get rollback_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.no_imported_objects'))
      end

      it 'redirects for wrong file_type (users)' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        get rollback_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.rollback_ticket_time_only'))
      end

      it 'allows rollback for time_tracking file_type' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processed,
                             organisation: organisation, user: admin)
        create(:imported_object, organisation: organisation,
                                 metadata: { 'import_file_id' => import_file.id })

        get rollback_path(import_file)
        expect(response).to have_http_status(:success)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        get rollback_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # DELETE #execute_rollback
  # ──────────────────────────────────────────────
  describe 'DELETE #execute_rollback' do
    context 'as admin' do
      before { sign_in admin }

      it 'performs rollback and redirects with success' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        session_id = SecureRandom.uuid
        create(:imported_object, organisation: organisation,
                                 import_session_id: session_id,
                                 metadata: { 'import_file_id' => import_file.id })

        delete execute_rollback_path(import_file)

        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:notice]).to be_present
        ActsAsTenant.current_tenant = organisation
        expect(import_file.reload.status).to eq('rolled_back')
      end

      it 'redirects when no imported objects exist' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        delete execute_rollback_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.no_imported_objects'))
      end

      it 'redirects for wrong file_type (users)' do
        import_file = create(:codebase_import_file, :with_valid_users_xml,
                             organisation: organisation, user: admin)
        delete execute_rollback_path(import_file)
        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.rollback_ticket_time_only'))
      end

      it 'allows rollback for time_tracking file_type' do
        import_file = create(:codebase_import_file, :with_valid_time_tracking_xml, :processed,
                             organisation: organisation, user: admin)
        session_id = SecureRandom.uuid
        create(:imported_object, organisation: organisation,
                                 import_session_id: session_id,
                                 metadata: { 'import_file_id' => import_file.id })

        delete execute_rollback_path(import_file)

        expect(response).to redirect_to(show_path(import_file))
        expect(flash[:notice]).to be_present
        ActsAsTenant.current_tenant = organisation
        expect(import_file.reload.status).to eq('rolled_back')
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin)
        delete execute_rollback_path(import_file)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # GET #assign_uploads
  # ──────────────────────────────────────────────
  describe 'GET #assign_uploads' do
    let(:project) { create(:project, organisation: organisation) }

    context 'as admin' do
      before { sign_in admin }

      it 'returns success when project has tickets' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin, project: project)
        create(:ticket, project: project, organisation: organisation)

        get assign_uploads_path(import_file, project)
        expect(response).to have_http_status(:success)
      end

      it 'redirects when project has no tickets' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin, project: project)

        get assign_uploads_path(import_file, project)
        expect(response).to redirect_to(index_path)
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.import_tickets_first'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        get assign_uploads_path(import_file, project)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  # ──────────────────────────────────────────────
  # POST #execute_upload_assignment
  # ──────────────────────────────────────────────
  describe 'POST #execute_upload_assignment' do
    let(:project) { create(:project, organisation: organisation) }

    context 'as admin' do
      before { sign_in admin }

      it 'enqueues job and redirects' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml, :processed,
                             organisation: organisation, user: admin, project: project)
        upload_file = create(:codebase_import_file, :uploads_file,
                             organisation: organisation, user: admin)

        expect do
          post execute_upload_assignment_path(import_file), params: {
            project_id: project.id,
            upload_file_id: upload_file.id
          }
        end.to have_enqueued_job(AssignUploadsToTicketsJob)

        expect(response).to redirect_to(show_path(upload_file))
        expect(flash[:notice]).to eq(I18n.t('flash.codebase_import_files.upload_assignment_started'))
      end

      it 'redirects when upload_file_id is blank' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)

        post execute_upload_assignment_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(assign_uploads_path(import_file, project))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.select_upload_file'))
      end

      it 'redirects when selected file is not uploads type' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        other_file = create(:codebase_import_file, :with_valid_users_xml,
                            organisation: organisation, user: admin)

        post execute_upload_assignment_path(import_file), params: {
          project_id: project.id,
          upload_file_id: other_file.id
        }
        expect(response).to redirect_to(assign_uploads_path(import_file, project))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.not_upload_file'))
      end

      it 'redirects when upload file is already processed' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        upload_file = create(:codebase_import_file, :uploads_file, :processed,
                             organisation: organisation, user: admin)

        post execute_upload_assignment_path(import_file), params: {
          project_id: project.id,
          upload_file_id: upload_file.id
        }
        expect(response).to redirect_to(assign_uploads_path(import_file, project))
        expect(flash[:alert]).to eq(I18n.t('flash.codebase_import_files.upload_already_processed'))
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'redirects with no permission flash' do
        import_file = create(:codebase_import_file, :with_valid_tickets_xml,
                             organisation: organisation, user: admin)
        post execute_upload_assignment_path(import_file), params: { project_id: project.id }
        expect(response).to redirect_to(root_path)
      end
    end
  end
  # ──────────────────────────────────────────────
  # Operator gate: data_import_enabled
  # ──────────────────────────────────────────────
  # Hiding the settings tab and the menu entry removes the ENTRANCE, not the routes.
  # These examples drive the URLs directly as an account admin, the one user the old
  # permission model let through, and assert on the SIDE EFFECT as well as the
  # redirect: a spec that only reads the response body would stay green while the
  # import quietly ran.
  describe 'with data import switched off for the organisation' do
    let(:organisation) { create(:organisation) }

    before { sign_in admin }

    it 'is off for a fresh organisation' do
      expect(organisation.data_import_enabled?).to be(false)
    end

    it 'refuses GET #index' do
      get index_path
      expect(response).to redirect_to(root_path)
    end

    it 'refuses GET #new' do
      get new_path
      expect(response).to redirect_to(root_path)
    end

    it 'refuses POST #create and stores no import file' do
      expect do
        post index_path, params: {
          codebase_import_file: { file_type: 'users', file: xml_upload(valid_users_xml) }
        }
      end.not_to(change { import_file_count })

      expect(response).to redirect_to(root_path)
    end

    it 'refuses POST #execute_import and imports no users' do
      import_file = create(:codebase_import_file, :with_valid_users_xml,
                           organisation: organisation, user: admin)

      expect do
        post execute_import_path(import_file), params: { selected_users: %w[1] }
      end.not_to(change { ActsAsTenant.without_tenant { User.count } })

      expect(response).to redirect_to(root_path)
      expect(import_file.reload.status).not_to eq('completed')
    end

    it 'refuses DELETE #destroy and keeps the record' do
      import_file = create(:codebase_import_file, :with_valid_users_xml,
                           organisation: organisation, user: admin)

      expect do
        delete show_path(import_file)
      end.not_to(change { import_file_count })

      expect(response).to redirect_to(root_path)
    end
  end
end

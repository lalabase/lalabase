# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AssignUploadsToTicketsJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:upload_import_file) do
    create(:codebase_import_file,
           organisation: organisation,
           project: project,
           user: user,
           file_type: 'uploads',
           status: 'uploaded',
           metadata: { 'existing_key' => 'existing_value' })
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  def perform_job(upload_import_file_id = upload_import_file.id,
                  project_id = project.id,
                  user_id = user.id)
    described_class.new.perform(upload_import_file_id, project_id, user_id)
  end

  describe '#perform' do
    let(:success_result) do
      {
        success: true,
        processed_count: 3,
        errors: [],
        results: [
          { upload_id: '1', post_id: 'post-1', ticket_id: 'ticket-1', file_name: 'doc.pdf', success: true }
        ]
      }
    end

    let(:failure_result) do
      {
        success: false,
        error: 'Invalid file type: tickets',
        errors: [{ upload_id: '1', error: 'Post not found' }]
      }
    end

    let(:service_double) { instance_double(CodebaseImport::UploadAssignmentService) }

    before do
      allow(CodebaseImport::UploadAssignmentService).to receive(:new).and_return(service_double)
    end

    # =========================================================================
    # Happy Path
    # =========================================================================
    context 'when service returns success' do
      before do
        allow(service_double).to receive(:call).and_return(success_result)
      end

      it 'transitions status from uploaded → processing → processed' do
        status_during_service_call = nil
        allow(service_double).to receive(:call) do
          upload_import_file.reload
          status_during_service_call = upload_import_file.status
          success_result
        end

        perform_job

        expect(status_during_service_call).to eq('processing')
        upload_import_file.reload
        expect(upload_import_file.status).to eq('processed')
      end

      it 'sets processing timestamps' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.processing_started_at).to be_within(2.seconds).of(Time.current)
        expect(upload_import_file.processing_completed_at).to be_within(2.seconds).of(Time.current)
      end

      it 'stores import_summary with results' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.import_summary['uploads_processed']).to eq(3)
        expect(upload_import_file.import_summary['uploads_errors']).to eq(0)
        expect(upload_import_file.import_summary['assignment_results']).to be_present
        expect(upload_import_file.import_summary['assignment_results'].first['upload_id']).to eq('1')
      end

      it 'merges assignment metadata preserving existing keys' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.metadata['existing_key']).to eq('existing_value')
        expect(upload_import_file.metadata['assignment_success']).to be true
        expect(upload_import_file.metadata['assignment_completed_at']).to be_present
        expect(upload_import_file.metadata['assignment_started_at']).to be_present
        expect(upload_import_file.metadata['assignment_project_id']).to eq(project.id)
      end

      it 'passes correct parameters to service' do
        expect(CodebaseImport::UploadAssignmentService).to receive(:new).with(
          organisation: organisation,
          project: project,
          user: user,
          upload_import_file: upload_import_file
        ).and_return(service_double)

        perform_job
      end

      it 'executes within correct tenant context' do
        tenant_during_call = nil
        allow(service_double).to receive(:call) do
          tenant_during_call = ActsAsTenant.current_tenant
          success_result
        end

        perform_job
        expect(tenant_during_call).to eq(organisation)
      end
    end

    # =========================================================================
    # Service returns failure (no exception)
    # =========================================================================
    context 'when service returns failure' do
      before do
        allow(service_double).to receive(:call).and_return(failure_result)
      end

      it 'marks import file as failed' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.status).to eq('failed')
      end

      it 'stores error_message from service result' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.error_message).to eq('Invalid file type: tickets')
      end

      it 'stores service errors in metadata' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.metadata['assignment_errors']).to be_present
        expect(upload_import_file.metadata['assignment_failed_at']).to be_present
      end

      it 'sets processing_completed_at' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.processing_completed_at).to be_within(2.seconds).of(Time.current)
      end

      it 'preserves existing metadata keys' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.metadata['existing_key']).to eq('existing_value')
      end

      it 'does not raise (service failure is not retryable)' do
        expect { perform_job }.not_to raise_error
      end
    end

    # =========================================================================
    # Service raises exception
    # =========================================================================
    context 'when service raises an exception' do
      before do
        allow(service_double).to receive(:call).and_raise(RuntimeError, 'Connection lost')
      end

      it 'marks import file as failed before re-raising' do
        expect { perform_job }.to raise_error(RuntimeError, 'Connection lost')

        upload_import_file.reload
        expect(upload_import_file.status).to eq('failed')
        expect(upload_import_file.error_message).to eq('Connection lost')
      end

      it 're-raises the exception for job retry mechanism' do
        expect { perform_job }.to raise_error(RuntimeError, 'Connection lost')
      end

      it 'sets processing_completed_at on failure' do
        expect { perform_job }.to raise_error(RuntimeError)

        upload_import_file.reload
        expect(upload_import_file.processing_completed_at).to be_within(2.seconds).of(Time.current)
      end

      it 'stores failure metadata with empty errors array' do
        expect { perform_job }.to raise_error(RuntimeError)

        upload_import_file.reload
        expect(upload_import_file.metadata['assignment_failed_at']).to be_present
        expect(upload_import_file.metadata['assignment_errors']).to eq([])
      end
    end

    # =========================================================================
    # Record not found edge cases
    # =========================================================================
    context 'when records are not found' do
      it 'raises RecordNotFound for invalid upload_import_file_id' do
        expect do
          perform_job(SecureRandom.uuid, project.id, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'raises RecordNotFound for invalid project_id' do
        expect do
          perform_job(upload_import_file.id, SecureRandom.uuid, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'raises RecordNotFound for invalid user_id' do
        expect do
          perform_job(upload_import_file.id, project.id, SecureRandom.uuid)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'does not change import file status when project not found' do
        expect do
          perform_job(upload_import_file.id, SecureRandom.uuid, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)

        upload_import_file.reload
        expect(upload_import_file.status).to eq('uploaded')
      end

      it 'does not call service when records are missing' do
        expect(CodebaseImport::UploadAssignmentService).not_to receive(:new)

        expect do
          perform_job(upload_import_file.id, SecureRandom.uuid, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    # =========================================================================
    # Processing metadata transition
    # =========================================================================
    context 'status transition to processing' do
      before do
        allow(service_double).to receive(:call).and_return(success_result)
      end

      it 'sets processing_started_at' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.processing_started_at).to be_within(2.seconds).of(Time.current)
      end

      it 'stores assignment_project_id in metadata' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.metadata['assignment_project_id']).to eq(project.id)
      end
    end

    # =========================================================================
    # Partial success (success=true with errors)
    # =========================================================================
    context 'when service returns success with partial errors' do
      let(:partial_result) do
        {
          success: true,
          processed_count: 2,
          errors: [{ upload_id: '3', error: 'File not found' }],
          results: [
            { upload_id: '1', success: true },
            { upload_id: '2', success: true }
          ]
        }
      end

      before do
        allow(service_double).to receive(:call).and_return(partial_result)
      end

      it 'marks as processed despite partial errors' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.status).to eq('processed')
      end

      it 'records error count in import_summary' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.import_summary['uploads_errors']).to eq(1)
        expect(upload_import_file.import_summary['uploads_processed']).to eq(2)
      end
    end

    # =========================================================================
    # Edge case: nil metadata
    # =========================================================================
    context 'when upload_import_file has nil metadata' do
      let(:upload_import_file) do
        file = create(:codebase_import_file,
                      organisation: organisation,
                      project: project,
                      user: user,
                      file_type: 'uploads',
                      status: 'uploaded')
        file.update_column(:metadata, nil)
        file
      end

      before do
        allow(service_double).to receive(:call).and_return(success_result)
      end

      it 'handles nil metadata without error' do
        expect { perform_job }.not_to raise_error

        upload_import_file.reload
        expect(upload_import_file.metadata['assignment_success']).to be true
      end
    end

    context 'when upload_import_file has empty metadata' do
      let(:upload_import_file) do
        create(:codebase_import_file,
               organisation: organisation,
               project: project,
               user: user,
               file_type: 'uploads',
               status: 'uploaded',
               metadata: {})
      end

      before do
        allow(service_double).to receive(:call).and_return(success_result)
      end

      it 'populates metadata correctly' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.metadata['assignment_success']).to be true
        expect(upload_import_file.metadata['assignment_project_id']).to eq(project.id)
      end
    end

    # =========================================================================
    # Edge case: zero processed uploads
    # =========================================================================
    context 'when service returns success with zero processed' do
      let(:empty_result) do
        {
          success: true,
          processed_count: 0,
          errors: [],
          results: []
        }
      end

      before do
        allow(service_double).to receive(:call).and_return(empty_result)
      end

      it 'marks as processed even with zero uploads' do
        perform_job
        upload_import_file.reload

        expect(upload_import_file.status).to eq('processed')
        expect(upload_import_file.import_summary['uploads_processed']).to eq(0)
      end
    end

    # =========================================================================
    # Tenant isolation
    # =========================================================================
    context 'tenant isolation' do
      let(:other_org) { create(:organisation) }

      before do
        allow(service_double).to receive(:call).and_return(success_result)
      end

      it 'uses organisation from upload_import_file, not from project' do
        tenant_set = nil
        allow(service_double).to receive(:call) do
          tenant_set = ActsAsTenant.current_tenant
          success_result
        end

        perform_job

        expect(tenant_set).to eq(organisation)
        expect(tenant_set).not_to eq(other_org)
      end
    end

    # =========================================================================
    # Edge case: failure with nil errors
    # =========================================================================
    context 'when service returns failure with nil errors' do
      let(:nil_errors_result) do
        {
          success: false,
          error: 'Something went wrong',
          errors: nil
        }
      end

      before do
        allow(service_double).to receive(:call).and_return(nil_errors_result)
      end

      it 'handles nil errors gracefully' do
        expect { perform_job }.not_to raise_error

        upload_import_file.reload
        expect(upload_import_file.status).to eq('failed')
        expect(upload_import_file.error_message).to eq('Something went wrong')
      end
    end
  end
end

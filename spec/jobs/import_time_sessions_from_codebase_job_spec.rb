# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportTimeSessionsFromCodebaseJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:import_file) do
    create(:codebase_import_file,
           :with_valid_time_tracking_xml,
           organisation: organisation,
           user: user,
           project: project)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '.queue_name' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe '#perform' do
    let(:success_result) do
      CodebaseImport::TimeSessionImporter::ImportResult.new(
        success: true,
        imported_count: 5,
        skipped_count: 1,
        error_count: 0
      )
    end

    let(:failure_result) do
      CodebaseImport::TimeSessionImporter::ImportResult.new(
        success: false,
        error: 'Import failed due to invalid data'
      )
    end

    let(:importer_double) { instance_double(CodebaseImport::TimeSessionImporter) }

    context 'when import succeeds' do
      before do
        allow(CodebaseImport::TimeSessionImporter).to receive(:new).and_return(importer_double)
        allow(importer_double).to receive(:call).and_return(success_result)
      end

      it 'creates the importer with correct arguments' do
        described_class.new.perform(import_file.id, project.id, user.id)

        expect(CodebaseImport::TimeSessionImporter).to have_received(:new).with(import_file, project, user)
      end

      it 'calls the importer' do
        described_class.new.perform(import_file.id, project.id, user.id)

        expect(importer_double).to have_received(:call)
      end

      it 'does not raise an error' do
        expect do
          described_class.new.perform(import_file.id, project.id, user.id)
        end.not_to raise_error
      end

      it 'logs success with counts' do
        allow(Rails.logger).to receive(:info)

        described_class.new.perform(import_file.id, project.id, user.id)

        expect(Rails.logger).to have_received(:info).with(
          a_string_matching(/completed.*imported=5.*skipped=1.*errors=0/)
        )
      end
    end

    context 'when importer returns failure result (no exception)' do
      before do
        allow(CodebaseImport::TimeSessionImporter).to receive(:new).and_return(importer_double)
        allow(importer_double).to receive(:call).and_return(failure_result)
      end

      it 'does not raise an error' do
        expect do
          described_class.new.perform(import_file.id, project.id, user.id)
        end.not_to raise_error
      end

      it 'logs the failure reason' do
        allow(Rails.logger).to receive(:error)

        described_class.new.perform(import_file.id, project.id, user.id)

        expect(Rails.logger).to have_received(:error).with(
          a_string_matching(/failed.*Import failed due to invalid data/)
        )
      end

      it 'does not update import_file status (importer handles that internally)' do
        described_class.new.perform(import_file.id, project.id, user.id)

        import_file.reload
        expect(import_file.status).to eq('uploaded')
      end
    end

    context 'when importer raises an exception' do
      before do
        allow(CodebaseImport::TimeSessionImporter).to receive(:new).and_return(importer_double)
        allow(importer_double).to receive(:call).and_raise(StandardError, 'Unexpected DB error')
      end

      it 're-raises the exception for job retry' do
        expect do
          described_class.new.perform(import_file.id, project.id, user.id)
        end.to raise_error(StandardError, 'Unexpected DB error')
      end

      it 'marks the import_file as failed' do
        begin
          described_class.new.perform(import_file.id, project.id, user.id)
        rescue StandardError
          # expected
        end

        import_file.reload
        expect(import_file.status).to eq('failed')
        expect(import_file.error_message).to eq('Unexpected DB error')
        expect(import_file.processing_completed_at).to be_present
      end

      it 'logs the error with truncated backtrace' do
        allow(Rails.logger).to receive(:error)

        begin
          described_class.new.perform(import_file.id, project.id, user.id)
        rescue StandardError
          # expected
        end

        expect(Rails.logger).to have_received(:error).with(
          a_string_matching(/exception.*StandardError.*Unexpected DB error/)
        )
      end
    end

    context 'when import_file does not exist' do
      let(:nonexistent_id) { SecureRandom.uuid }

      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(nonexistent_id, project.id, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'does not attempt to mark a nonexistent file as failed' do
        expect do
          described_class.new.perform(nonexistent_id, project.id, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)

        expect(CodebaseImportFile.find_by(id: nonexistent_id)).to be_nil
      end
    end

    context 'when project does not exist' do
      let(:nonexistent_id) { SecureRandom.uuid }

      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(import_file.id, nonexistent_id, user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'marks the import_file as failed' do
        begin
          described_class.new.perform(import_file.id, nonexistent_id, user.id)
        rescue ActiveRecord::RecordNotFound
          # expected
        end

        import_file.reload
        expect(import_file.status).to eq('failed')
      end
    end

    context 'when user does not exist' do
      let(:nonexistent_id) { SecureRandom.uuid }

      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(import_file.id, project.id, nonexistent_id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'marks the import_file as failed' do
        begin
          described_class.new.perform(import_file.id, project.id, nonexistent_id)
        rescue ActiveRecord::RecordNotFound
          # expected
        end

        import_file.reload
        expect(import_file.status).to eq('failed')
      end
    end

    context 'when import_file is deleted before rescue can update it' do
      before do
        allow(CodebaseImport::TimeSessionImporter).to receive(:new).and_return(importer_double)
        allow(importer_double).to receive(:call).and_raise(StandardError, 'Some error')
        # Simulate the import_file being deleted concurrently
        allow(CodebaseImportFile).to receive(:find_by).with(id: import_file.id).and_return(nil)
      end

      it 're-raises the original error without failing on the status update' do
        allow(CodebaseImportFile).to receive(:find).and_call_original

        expect do
          described_class.new.perform(import_file.id, project.id, user.id)
        end.to raise_error(StandardError, 'Some error')
      end
    end

    context 'when importer constructor raises ValidationError' do
      before do
        allow(CodebaseImport::TimeSessionImporter).to receive(:new)
          .and_raise(CodebaseImport::TimeSessionImporter::ValidationError, 'Project is required')
      end

      it 're-raises the validation error' do
        expect do
          described_class.new.perform(import_file.id, project.id, user.id)
        end.to raise_error(CodebaseImport::TimeSessionImporter::ValidationError)
      end

      it 'marks the import_file as failed with the validation message' do
        begin
          described_class.new.perform(import_file.id, project.id, user.id)
        rescue CodebaseImport::TimeSessionImporter::ValidationError
          # expected
        end

        import_file.reload
        expect(import_file.status).to eq('failed')
        expect(import_file.error_message).to eq('Project is required')
      end
    end

    context 'with partial success result (some errors)' do
      let(:partial_result) do
        CodebaseImport::TimeSessionImporter::ImportResult.new(
          success: true,
          imported_count: 8,
          skipped_count: 2,
          error_count: 3,
          errors: ['Time Session 1: invalid date', 'Time Session 5: missing user']
        )
      end

      before do
        allow(CodebaseImport::TimeSessionImporter).to receive(:new).and_return(importer_double)
        allow(importer_double).to receive(:call).and_return(partial_result)
      end

      it 'logs success even with partial errors (importer considers it success)' do
        allow(Rails.logger).to receive(:info)

        described_class.new.perform(import_file.id, project.id, user.id)

        expect(Rails.logger).to have_received(:info).with(
          a_string_matching(/completed.*imported=8.*skipped=2.*errors=3/)
        )
      end
    end
  end

  describe 'job enqueueing', :active_job_test_adapter do
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = original_adapter
    end

    it 'can be enqueued with correct arguments' do
      expect do
        described_class.perform_later(import_file.id, project.id, user.id)
      end.to have_enqueued_job(described_class)
        .with(import_file.id, project.id, user.id)
        .on_queue('default')
    end
  end
end

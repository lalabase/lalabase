# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportTicketsFromCodebaseJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:import_file) do
    create(:codebase_import_file, :with_valid_tickets_xml,
           organisation: organisation, user: user)
  end
  let(:status_mappings) { { 'Open' => 'open' } }
  let(:priority_mappings) { { 'High' => 'high' } }

  let(:success_result) do
    CodebaseImport::TicketImporter::ImportResult.new(
      success: true, imported_count: 1, error_count: 0
    )
  end

  let(:failure_result) do
    CodebaseImport::TicketImporter::ImportResult.new(
      success: false, error: 'Import failed: invalid data'
    )
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '#perform' do
    context 'when import succeeds' do
      it 'creates importer with correct arguments and completes without error' do
        importer = instance_double(CodebaseImport::TicketImporter, call: success_result)

        expect(CodebaseImport::TicketImporter).to receive(:new).with(
          import_file, project, status_mappings, priority_mappings, user,
          include_tags: false
        ).and_return(importer)

        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, user.id
          )
        end.not_to raise_error
      end

      it 'passes include_tags option through to importer' do
        importer = instance_double(CodebaseImport::TicketImporter, call: success_result)

        expect(CodebaseImport::TicketImporter).to receive(:new).with(
          import_file, project, status_mappings, priority_mappings, user,
          include_tags: true
        ).and_return(importer)

        described_class.new.perform(
          import_file.id, project.id, status_mappings, priority_mappings, user.id,
          include_tags: true
        )
      end
    end

    context 'when importer returns failure result' do
      it 'raises the error message from the result' do
        importer = instance_double(CodebaseImport::TicketImporter, call: failure_result)
        allow(CodebaseImport::TicketImporter).to receive(:new).and_return(importer)

        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error('Import failed: invalid data')
      end
    end

    context 'when importer raises an exception' do
      it 're-raises the exception' do
        importer = instance_double(CodebaseImport::TicketImporter)
        allow(importer).to receive(:call).and_raise(
          CodebaseImport::TicketImporter::ImportError, 'XML parsing failed'
        )
        allow(CodebaseImport::TicketImporter).to receive(:new).and_return(importer)

        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(CodebaseImport::TicketImporter::ImportError, 'XML parsing failed')
      end
    end

    context 'when import_file does not exist' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(
            SecureRandom.uuid, project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when project does not exist' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(
            import_file.id, SecureRandom.uuid, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when user does not exist' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, SecureRandom.uuid
          )
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when organisation does not match' do
      let(:other_organisation) do
        ActsAsTenant.without_tenant { create(:organisation) }
      end
      let(:other_project) do
        ActsAsTenant.without_tenant { create(:project, organisation: other_organisation) }
      end

      it 'raises OrganisationMismatchError' do
        expect do
          described_class.new.perform(
            import_file.id, other_project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(ImportTicketsFromCodebaseJob::OrganisationMismatchError)
      end

      it 'does not create the importer' do
        expect(CodebaseImport::TicketImporter).not_to receive(:new)

        expect do
          described_class.new.perform(
            import_file.id, other_project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(ImportTicketsFromCodebaseJob::OrganisationMismatchError)
      end

      it 'includes both organisation IDs in the error message' do
        expect do
          described_class.new.perform(
            import_file.id, other_project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(
          ImportTicketsFromCodebaseJob::OrganisationMismatchError,
          /#{other_organisation.id}.*#{organisation.id}/
        )
      end
    end

    context 'tenant context' do
      it 'sets the correct tenant before calling the importer' do
        captured_tenant = nil
        importer = instance_double(CodebaseImport::TicketImporter)
        allow(importer).to receive(:call) do
          captured_tenant = ActsAsTenant.current_tenant
          success_result
        end
        allow(CodebaseImport::TicketImporter).to receive(:new).and_return(importer)

        described_class.new.perform(
          import_file.id, project.id, status_mappings, priority_mappings, user.id
        )

        expect(captured_tenant).to eq(organisation)
      end
    end

    context 'job enqueuing' do
      it 'enqueues on the default queue' do
        expect(described_class.new.queue_name).to eq('default')
      end

      it 'can be enqueued with perform_later' do
        ActiveJob::Base.queue_adapter = :test

        expect do
          described_class.perform_later(
            import_file.id, project.id, status_mappings, priority_mappings, user.id
          )
        end.to have_enqueued_job(described_class).with(
          import_file.id, project.id, status_mappings, priority_mappings, user.id
        )
      end
    end

    context 'with partial failure (success with errors)' do
      let(:partial_result) do
        CodebaseImport::TicketImporter::ImportResult.new(
          success: true, imported_count: 8, error_count: 2,
          errors: ['Ticket 5: invalid status', 'Ticket 9: missing subject']
        )
      end

      it 'does not raise when import is successful despite individual errors' do
        importer = instance_double(CodebaseImport::TicketImporter, call: partial_result)
        allow(CodebaseImport::TicketImporter).to receive(:new).and_return(importer)

        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, user.id
          )
        end.not_to raise_error
      end
    end

    context 'with empty mappings' do
      let(:empty_status_mappings) { {} }
      let(:empty_priority_mappings) { {} }

      it 'passes empty mappings to the importer' do
        importer = instance_double(CodebaseImport::TicketImporter, call: success_result)

        expect(CodebaseImport::TicketImporter).to receive(:new).with(
          import_file, project, empty_status_mappings, empty_priority_mappings, user,
          include_tags: false
        ).and_return(importer)

        described_class.new.perform(
          import_file.id, project.id, empty_status_mappings, empty_priority_mappings, user.id
        )
      end
    end

    context 'with extra options' do
      it 'accepts and ignores unknown keyword arguments' do
        importer = instance_double(CodebaseImport::TicketImporter, call: success_result)
        allow(CodebaseImport::TicketImporter).to receive(:new).and_return(importer)

        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, user.id,
            include_tags: false, some_future_option: 'value'
          )
        end.not_to raise_error
      end
    end

    context 'error logging' do
      it 'logs the error before re-raising' do
        importer = instance_double(CodebaseImport::TicketImporter)
        allow(importer).to receive(:call).and_raise(RuntimeError, 'unexpected failure')
        allow(CodebaseImport::TicketImporter).to receive(:new).and_return(importer)

        expect(Rails.logger).to receive(:error).with(/ImportTicketsFromCodebaseJob failed.*unexpected failure/)

        expect do
          described_class.new.perform(
            import_file.id, project.id, status_mappings, priority_mappings, user.id
          )
        end.to raise_error(RuntimeError)
      end
    end
  end
end

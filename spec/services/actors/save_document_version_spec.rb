# frozen_string_literal: true

# spec/services/actors/save_document_version_spec.rb

require 'rails_helper'

RSpec.describe Actors::SaveDocumentVersion, type: :service do
  include ActiveJob::TestHelper
  ActiveJob::Base.queue_adapter = :test

  # Mock objects instead of factories
  let(:organisation) { double('Organisation', id: 'org-1') }
  let(:user) { double('User', id: 'user-1', organisation: organisation) }
  let(:project) { double('Project', id: 'proj-1', organisation: organisation) }

  # Mock for DocumentVersion
  let(:document_version) do
    double('DocumentVersion',
           id: 'version-1',
           persisted?: true,
           title: 'Version 1',
           create_embeddings: true,
           present?: true)
  end

  # Mock for Document with all required methods
  let(:document) do
    double('Document',
           id: 'doc-1',
           organisation: organisation,
           project: project,
           current_version: nil,
           save!: true,
           reload: double('Document', current_version: document_version),
           next_version_number: 1,
           lock!: true,
           document_versions: double('DocumentVersionsCollection'))
  end

  # Mock for ActiveRecord::RecordInvalid with i18n_scope
  let(:invalid_record_class) do
    Class.new do
      attr_reader :errors

      def initialize(errors)
        @errors = errors
      end

      def self.i18n_scope
        :activerecord
      end
    end
  end

  # Valid parameters for the DocumentVersion
  let(:valid_params) do
    {
      'title' => 'Version 1',
      'description' => 'Initial version',
      'create_embeddings' => true,
      'create_summary' => true,
      'organisation' => organisation,
      'document_version_file' => double('FileUpload', tempfile: double('Tempfile'), original_filename: 'test_file.txt')
    }
  end

  # Invalid parameters for the DocumentVersion (e.g. missing title)
  let(:invalid_params) do
    {
      'title' => '', # Invalid, because a title is required
      'description' => 'No title provided',
      'create_embeddings' => true,
      'organisation' => organisation,
      'document_version_file' => double('FileUpload', tempfile: double('Tempfile'), original_filename: 'test_file.txt')
    }
  end

  before do
    # Clear all enqueued and performed jobs before each test
    clear_enqueued_jobs
    clear_performed_jobs

    # Stub DocumentVersion.count for the change expectation
    allow(DocumentVersion).to receive(:count).and_return(0, 1)

    # Stub the document_versions collection
    allow(document.document_versions).to receive(:create!).and_return(document_version)

    # Allow setting current_version
    allow(document).to receive(:current_version=)

    # Stub the DocumentVersionProcessingJob
    allow(DocumentVersionProcessingJob).to receive(:perform_later)
  end

  describe '#call' do
    subject { described_class.new(document: document, params: valid_params, current_user: user) }

    context 'wenn das Speichern erfolgreich ist' do
      before do
        allow(document.document_versions).to receive(:create!).and_return(document_version)
        allow(document).to receive(:current_version=)
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
      end

      it 'erstellt erfolgreich eine neue Dokumentenversion' do
        allow(document).to receive(:next_version_number).and_return(3)
        expect(document.document_versions).to receive(:create!).with(
          number: 3,
          title: valid_params['title'],
          description: valid_params['description'],
          document_version_file: valid_params['document_version_file'],
          # No create_embeddings: the column's default is the answer since
          # doc/notizen_immer_indexiert_plan.md; an explicit nil used to override it.
          create_summary: valid_params['create_summary'],
          organisation: organisation,
          user: user
        ).once

        subject.call
      end

      # The next number is read under the document's row lock (review of #779):
      # a second upload at the same moment, or the stock's numbering
      # (Documents::NumberVersions), waits for this commit instead of reading the
      # same maximum. lock! reloads, so it must come before the read.
      it 'nimmt die Zeilensperre des Dokuments, bevor es die naechste Nummer liest' do
        expect(document).to receive(:lock!).ordered
        expect(document).to receive(:next_version_number).ordered.and_return(3)

        subject.call
      end

      it 'setzt die aktuelle Version des Dokuments' do
        expect(document).to receive(:current_version=).with(document_version).once
        expect(document).to receive(:save!).once

        subject.call
      end

      it 'gibt ein erfolgreiches Result-Objekt zurück' do
        result = subject.call
        expect(result).to be_success
        expect(result.resource).to eq(document)
      end

      it 'plant den DocumentVersionProcessingJob' do
        expect(DocumentVersionProcessingJob).to receive(:perform_later).with(document_version).once

        subject.call
      end
    end

    context 'wenn ein Validierungsfehler auftritt' do
      before do
        # Build an object usable as the record inside ActiveRecord::RecordInvalid
        mock_errors = double('Errors', full_messages: ['Test error'])
        invalid_record = invalid_record_class.new(mock_errors)

        # Make document_versions.create! raise a validation error
        allow(document.document_versions).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid_record))

        # @document_version stays nil when the exception is raised
        allow(document).to receive(:document_versions).and_return(document.document_versions)
        allow(document_version).to receive(:present?).and_return(false)
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
      end

      # Regression guard for the missing-`return` bug: a RecordInvalid inside the
      # transaction must surface as a failed Result, not a swallowed success.
      it 'gibt ein fehlgeschlagenes Result mit den Validierungsfehlern zurück' do
        result = subject.call
        expect(result).not_to be_success
        expect(result.errors).to include('Test error')
      end

      it 'startet keinen DocumentVersionProcessingJob' do
        # No version was created, so no processing job must be scheduled
        expect(DocumentVersionProcessingJob).not_to receive(:perform_later)

        subject.call
      end

      it 'bricht die Transaktion ab, bevor das Dokument gespeichert wird' do
        # A create! failure must short-circuit: the document save must not run.
        # Kills a mutation that swallows the create! error and proceeds to save!.
        expect(document).not_to receive(:save!)

        subject.call
      end
    end

    context 'wenn ein unerwarteter Fehler auftritt' do
      before do
        # Make document_versions.create! raise a generic error
        allow(document.document_versions).to receive(:create!).and_raise(StandardError.new('Unerwarteter Fehler'))

        # @document_version stays nil when the exception is raised
        allow(document).to receive(:document_versions).and_return(document.document_versions)
        allow(document_version).to receive(:present?).and_return(false)
      end

      # With the BaseActor template an unexpected StandardError is re-raised in
      # dev/test (raise_unexpected? == true) so bugs surface loudly; in
      # production it is logged and turned into a failure Result instead.
      it 'reicht einen unerwarteten Fehler in dev/test durch und plant keinen Job' do
        expect(DocumentVersionProcessingJob).not_to receive(:perform_later)

        expect { subject.call }.to raise_error(StandardError, 'Unerwarteter Fehler')
      end
    end
  end
end

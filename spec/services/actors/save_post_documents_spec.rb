# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::SavePostDocuments do
  # Create mock objects to work around factory issues
  let(:organisation) { double('Organisation', id: 'org-1') }
  let(:project) { double('Project', id: 'proj-1', organisation: organisation) }
  let(:ticket) { double('Ticket', id: 'ticket-1', project: project, organisation: organisation) }
  let(:user) { double('User', id: 'user-1') }

  # Mock Post object with stubs for the required methods
  let(:post_record) do
    double('Post',
           id: 'post-1',
           ticket: ticket,
           user: user,
           organisation: organisation,
           post_documents: [])
  end

  # Mock for a file upload
  let(:file) { double('UploadedFile', present?: true) }
  let(:post_document_params) { { post: { post_document_files: [file] } } }

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

  describe '#call' do
    subject { described_class.new(post: post_record, params: post_document_params) }

    before do
      # Stub the necessary methods
      allow(post_record.post_documents).to receive(:count).and_return(0, 1)
      allow(PostDocument).to receive(:create).and_return(double('PostDocument'))
      allow(PostDocumentProcessingJob).to receive(:perform_later)
    end

    it 'erstellt ein PostDocument' do
      expect(PostDocument).to receive(:create).exactly(1).times
      subject.call
    end

    it 'gibt ein erfolgreiches Result-Objekt zurück' do
      result = subject.call
      expect(result).to be_success
      expect(result.resource).to eq(post_record)
    end

    it 'startet PostDocumentProcessingJob für jedes Dokument' do
      expect(PostDocumentProcessingJob).to receive(:perform_later).exactly(1).times
      subject.call
    end

    context 'ohne Dateien' do
      let(:post_document_params) { { post: { post_document_files: [] } } }

      it 'erstellt keine Dokumente' do
        expect(PostDocument).not_to receive(:create)
        subject.call
      end

      it 'gibt trotzdem ein erfolgreiches Result zurück' do
        result = subject.call
        expect(result).to be_success
      end
    end

    context 'mit nil-Dateien' do
      let(:post_document_params) { { post: { post_document_files: [nil] } } }

      it 'ignoriert nil-Dateien' do
        expect(PostDocument).not_to receive(:create)
        subject.call
      end
    end

    context 'bei einem Fehler' do
      it 'gibt ein nicht erfolgreiches Result zurück' do
        # Create an object that can be used for ActiveRecord::RecordInvalid
        mock_errors = double('Errors', full_messages: ['Test error'])
        invalid_record = invalid_record_class.new(mock_errors)

        # Use this object for the exception
        allow(PostDocument).to receive(:create).and_raise(ActiveRecord::RecordInvalid.new(invalid_record))

        result = subject.call
        expect(result).not_to be_success
        expect(result.errors).to be_present
      end
    end
  end
end

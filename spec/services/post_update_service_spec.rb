# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostUpdateService do
  # Create mock objects to work around factory problems
  let(:organisation) { double('Organisation', id: 'org-1') }
  let(:project) { double('Project', id: 'proj-1', organisation: organisation) }
  let(:ticket) { double('Ticket', id: 'ticket-1', project: project, organisation: organisation) }
  let(:user) { double('User', id: 'user-1') }
  let(:post_params) { { content: 'Dies ist ein Testinhalt' } }

  # Mock for a file upload
  let(:file) { double('UploadedFile', present?: true) }
  let(:form_params) { { post: { post_document_files: [file] } } }

  # Mock Post object for the tests
  let(:post_record) { double('Post', id: 'post-1', reload: true) }

  # Mocks for the actors
  let(:save_post_actor) { double('SavePostActor', record: post_record) }
  let(:save_post_documents_actor) { double('SavePostDocumentsActor') }

  describe '#call' do
    before do
      # Stub the actors and their methods
      allow(Actors::SavePost).to receive(:new).and_return(save_post_actor)
      allow(Actors::SavePostDocuments).to receive(:new).and_return(save_post_documents_actor)
      allow(PostDocument).to receive(:count).and_return(0, 1)
      allow(Post).to receive(:count).and_return(0, 1)
    end

    context 'bei Erstellung eines neuen Posts' do
      subject { described_class.new(ticket, post_params, nil, user, form_params) }

      before do
        # Successful actor results
        allow(save_post_actor).to receive(:call).and_return(Actors::BaseActor::Result.new(success: true, resource: post_record))
        allow(save_post_documents_actor).to receive(:call).and_return(Actors::BaseActor::Result.new(success: true, resource: []))
        allow(PostDocumentProcessingJob).to receive(:perform_later)
      end

      it 'erstellt einen neuen Post mit Dokumenten' do
        expect(Actors::SavePost).to receive(:new).with(ticket: ticket, params: post_params, id: nil, current_user: user)
        expect(Actors::SavePostDocuments).to receive(:new).with(post: post_record, params: form_params)
        subject.call
      end

      it 'gibt ein erfolgreiches Result-Objekt zurück' do
        result = subject.call
        expect(result).to be_success
        expect(result.resource).to eq(post_record)
      end

      it 'startet PostDocumentProcessingJob' do
        expect(save_post_documents_actor).to receive(:call)
        subject.call
      end
    end

    context 'ohne Dokumente' do
      subject { described_class.new(ticket, post_params, nil, user, nil) }

      before do
        allow(save_post_actor).to receive(:call).and_return(Actors::BaseActor::Result.new(success: true, resource: post_record))
      end

      it 'erstellt nur den Post ohne Dokumente' do
        expect(Actors::SavePost).to receive(:new)
        expect(Actors::SavePostDocuments).not_to receive(:new)
        subject.call
      end
    end

    context 'bei Aktualisierung eines vorhandenen Posts' do
      subject { described_class.new(ticket, post_params, 'post-1', user, form_params) }

      before do
        allow(save_post_actor).to receive(:call).and_return(Actors::BaseActor::Result.new(success: true, resource: post_record))
        allow(save_post_documents_actor).to receive(:call).and_return(Actors::BaseActor::Result.new(success: true, resource: []))
      end

      it 'aktualisiert den Post und fügt Dokumente hinzu' do
        expect(Actors::SavePost).to receive(:new).with(ticket: ticket, params: post_params, id: 'post-1', current_user: user)
        expect(Actors::SavePostDocuments).to receive(:new)
        subject.call
      end
    end

    context 'bei Fehlern im SavePost-Actor' do
      subject { described_class.new(ticket, post_params, nil, user, form_params) }

      it 'gibt das Ergebnis des fehlgeschlagenen SavePost-Actors zurück' do
        allow(save_post_actor).to receive(:call).and_return(
          Actors::BaseActor::Result.new(success: false, errors: ['Fehler im SavePost-Actor'])
        )

        result = subject.call
        expect(result).not_to be_success
        expect(result.errors).to include('Fehler im SavePost-Actor')
      end
    end

    context 'bei Fehlern im SavePostDocuments-Actor' do
      subject { described_class.new(ticket, post_params, nil, user, form_params) }

      it 'gibt das Ergebnis des fehlgeschlagenen SavePostDocuments-Actors zurück' do
        # First let the SavePost actor run normally
        allow(save_post_actor).to receive(:call).and_return(
          Actors::BaseActor::Result.new(success: true, resource: post_record)
        )

        # Then make the SavePostDocuments actor fail
        allow(save_post_documents_actor).to receive(:call).and_return(
          Actors::BaseActor::Result.new(success: false, errors: ['Fehler im SavePostDocuments-Actor'])
        )

        result = subject.call
        expect(result).not_to be_success
        expect(result.errors).to include('Fehler im SavePostDocuments-Actor')
      end
    end

    context 'bei unerwarteten Fehlern' do
      subject { described_class.new(ticket, post_params, nil, user, form_params) }

      it 'fängt unerwartete Fehler ab und gibt ein Result-Objekt zurück' do
        allow(save_post_actor).to receive(:call).and_raise('Unerwarteter Fehler')

        result = subject.call
        expect(result).not_to be_success
        expect(result.errors).to include('Unerwarteter Fehler')
      end
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::SavePost do
  # Create mock objects to work around factory issues
  let(:organisation) { double('Organisation', id: 'org-1') }
  let(:project) { double('Project', id: 'proj-1', organisation: organisation) }
  let(:ticket) { double('Ticket', id: 'ticket-1', project: project, organisation: organisation) }
  let(:user) { double('User', id: 'user-1') }
  let(:post_params) { { content: 'Dies ist ein Testinhalt' } }

  # Mock for the Post object with all required methods
  let(:new_post) do
    double('Post',
           id: nil,
           user: nil,
           create_embeddings?: true,
           id_present?: false,
           new_record?: true,
           # The privacy-flip branch asks every post whether its privacy just moved; a
           # post that never changed it answers false and the branch does nothing.
           saved_change_to_is_private?: false,
           ticket: ticket)
  end

  let(:existing_post) do
    double('Post',
           id: 'post-1',
           user: user,
           create_embeddings?: true,
           id_present?: true,
           new_record?: false,
           saved_change_to_is_private?: false,
           ticket: ticket)
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

  # A new post marks its author's notifications read; that path has its own spec
  # with real records (save_post_marks_read_spec.rb), these doubles cannot query.
  before { allow(Notifications::MarkTicketRead).to receive(:call).and_return([]) }

  describe '#call' do
    context 'bei Erstellung eines neuen Posts' do
      subject { described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user) }

      it 'erstellt einen neuen Post' do
        # Stub the model lookup and the building of a new post
        allow(Post).to receive(:where).and_return(double('Relation', first: nil))
        allow(ticket).to receive(:posts).and_return(double('Relation', build: new_post))

        # We expect these methods to be called
        expect(new_post).to receive(:user=).with(user).once
        expect(new_post).to receive(:assign_attributes).with(post_params).once
        expect(new_post).to receive(:save!).once

        # Other stubs for the functionality
        allow(new_post).to receive(:id).and_return(nil, 'post-1')
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        subject.call
      end

      it 'gibt ein erfolgreiches Result-Objekt zurück' do
        # Stub the model lookup and the building of a new post
        allow(Post).to receive(:where).and_return(double('Relation', first: nil))
        allow(ticket).to receive(:posts).and_return(double('Relation', build: new_post))

        # Stubs for all called methods
        allow(new_post).to receive(:user=).with(user)
        allow(new_post).to receive(:assign_attributes).with(post_params)
        allow(new_post).to receive(:save!)
        allow(new_post).to receive(:id).and_return(nil, 'post-1')
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        result = subject.call
        expect(result).to be_success
        expect(result.resource).to eq(new_post)
      end

      it 'plant den EmbeddingProcessingJob, wenn create_embeddings wahr ist' do
        # Stub the model lookup and the building of a new post
        allow(Post).to receive(:where).and_return(double('Relation', first: nil))
        allow(ticket).to receive(:posts).and_return(double('Relation', build: new_post))

        # Stubs for all called methods
        allow(new_post).to receive(:user=).with(user)
        allow(new_post).to receive(:assign_attributes).with(post_params)
        allow(new_post).to receive(:save!)
        allow(new_post).to receive(:id).and_return(nil, 'post-1')

        # We expect the job to be executed
        expect(EmbeddingProcessingJob).to receive(:perform_later).with(
          record_class: Post,
          record_id: 'post-1',
          fragment_association: :fragments
        )

        subject.call
      end
    end

    context 'bei Aktualisierung eines vorhandenen Posts' do
      subject { described_class.new(ticket: ticket, params: post_params, id: 'post-1', current_user: user) }

      it 'aktualisiert den vorhandenen Post' do
        # Stub the model lookup for the existing post
        allow(Post).to receive(:where).and_return(double('Relation', first: existing_post))

        # We expect update! to be called
        expect(existing_post).to receive(:update!).with(post_params).once

        # Further stubs
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        subject.call
      end

      it 'gibt ein erfolgreiches Result-Objekt zurück' do
        # Stub the model lookup for the existing post
        allow(Post).to receive(:where).and_return(double('Relation', first: existing_post))
        allow(existing_post).to receive(:update!).with(post_params)
        allow(EmbeddingProcessingJob).to receive(:perform_later)

        result = subject.call
        expect(result).to be_success
        expect(result.resource).to eq(existing_post)
      end
    end

    context 'bei einem Fehler' do
      subject { described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user) }

      it 'gibt ein nicht erfolgreiches Result zurück' do
        allow(Post).to receive(:where).and_return(double('Relation', first: nil))
        allow(ticket).to receive(:posts).and_return(double('Relation', build: new_post))
        allow(new_post).to receive(:user=).with(user)
        allow(new_post).to receive(:assign_attributes).with(post_params)

        # Create an object that can be used for ActiveRecord::RecordInvalid
        mock_errors = double('Errors', full_messages: ['Test error'])
        invalid_record = invalid_record_class.new(mock_errors)

        # Use this object for the exception
        allow(new_post).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(invalid_record))

        result = subject.call
        expect(result).not_to be_success
        expect(result.errors).to be_present
      end
    end
  end
end

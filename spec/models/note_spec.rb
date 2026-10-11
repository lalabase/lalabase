# frozen_string_literal: true

# == Schema Information
#
# Table name: notes
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  description              :text
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  lock_version             :integer          default(0), not null
#  markdown_body            :text
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  creator_id               :uuid             not null
#  organisation_id          :uuid             not null
#  project_id               :uuid             not null
#
# Indexes
#
#  index_notes_on_creator_id       (creator_id)
#  index_notes_on_organisation_id  (organisation_id)
#  index_notes_on_project_id       (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#
require 'rails_helper'

RSpec.describe Note, type: :model do
  let(:organisation) { create(:organisation) }

  describe 'validations' do
    before do
      ActsAsTenant.current_tenant = organisation
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    it { should validate_presence_of(:title) }
    it { should validate_presence_of(:content) }
  end

  describe 'associations' do
    before do
      ActsAsTenant.current_tenant = organisation
    end

    after do
      ActsAsTenant.current_tenant = nil
    end
    # NOTE: organisation association is handled by acts_as_tenant, not a standard belongs_to
    it { should have_many(:fragments).dependent(:delete_all) }
    it { should have_rich_text(:content) }

    it 'creates a note with expected attributes' do
      ActsAsTenant.with_tenant(organisation) do
        note = create(:note, title: 'Test Note', content: 'Test Content')
        expect(note.title).to eq('Test Note')
        expect(note.content.to_plain_text).to eq('Test Content')
        expect(note.description).to eq('Test Description')
        expect(note.project).to be_present
        expect(note.organisation).to eq(organisation)
      end
    end
  end

  describe 'callbacks' do
    describe '#extract_plain_text_content' do
      it 'extracts plain text from rich text content before save' do
        ActsAsTenant.with_tenant(organisation) do
          note = create(:note, content: '<p>This is <strong>rich</strong> text</p>')
          expect(note.plain_text_version).to eq('This is rich text')
          expect(note.plain_text_word_count).to eq(4)
        end
      end

      it 'correctly counts words in plain text' do
        ActsAsTenant.with_tenant(organisation) do
          note = create(:note, content: 'Word count   should be   accurate   with   multiple spaces')
          expect(note.plain_text_word_count).to eq(8)
        end
      end

      it 'handles empty content' do
        ActsAsTenant.with_tenant(organisation) do
          # Content cannot be empty due to validation, so we bypass validation for this test
          note = build(:note)
          note.content = nil
          note.save(validate: false)
          expect(note.plain_text_version).to eq('')
          expect(note.plain_text_word_count).to eq(0)
        end
      end
    end
  end

  describe 'instance methods' do
    let(:project) { create(:project, organisation: organisation) }
    let(:note) { create(:note, project: project, organisation: organisation) }

    describe '#total_time_expenditure' do
      it 'returns the sum of durations for all time sessions of the project' do
        ActsAsTenant.with_tenant(organisation) do
          # Create time sessions for the project (duration is in MINUTES; a
          # single booking is capped at one day, TimeSession::MAX_DURATION_MINUTES)
          create(:time_session, project: project, duration: 60) # 1 hour
          create(:time_session, project: project, duration: 30) # 30 minutes

          expect(note.total_time_expenditure).to eq(90) # 1.5 hours in minutes
        end
      end

      it 'returns 0 when there are no time sessions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(note.total_time_expenditure).to eq(0)
        end
      end
    end

    describe '#formatted_time_expenditure' do
      it 'formats the total time expenditure as a readable string' do
        ActsAsTenant.with_tenant(organisation) do
          # Create time sessions for the project (duration is in MINUTES)
          create(:time_session, project: project, duration: 60) # 1 hour
          create(:time_session, project: project, duration: 30) # 30 minutes

          # Mock the TimeSession.format_duration method
          allow(TimeSession).to receive(:format_duration).with(90).and_return('1h 30m')

          expect(note.formatted_time_expenditure).to eq('1h 30m')
          expect(TimeSession).to have_received(:format_duration).with(90)
        end
      end
    end
  end

  describe 'multi-tenant behavior' do
    it 'scopes notes to the current organisation' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      note1 = nil
      note2 = nil

      ActsAsTenant.with_tenant(org1) do
        note1 = create(:note, title: 'Note for Org1')
        expect(Note.count).to eq(1)
        expect(Note.first.title).to eq('Note for Org1')
      end

      ActsAsTenant.with_tenant(org2) do
        note2 = create(:note, title: 'Note for Org2')
        expect(Note.count).to eq(1)
        expect(Note.first.title).to eq('Note for Org2')
      end

      # Verify both notes exist in the database
      expect(Note.unscoped.count).to eq(2)
    end
  end

  describe 'embeddings behavior' do
    it 'can be configured to create embeddings' do
      ActsAsTenant.with_tenant(organisation) do
        note = create(:note, create_embeddings: true)
        expect(note.create_embeddings?).to be true
      end
    end

    it 'can store embedding creation errors' do
      ActsAsTenant.with_tenant(organisation) do
        note = create(:note, embedding_creation_error: 'API connection failed')
        expect(note.embedding_creation_error).to eq('API connection failed')
      end
    end
  end

  describe 'dependency behavior' do
    let(:project) { create(:project, organisation: organisation) }

    it 'destroys dependent fragments when destroyed' do
      ActsAsTenant.with_tenant(organisation) do
        note = create(:note, project: project)
        fragment = create(:fragment, :for_note, fragmentable: note, organisation: organisation)

        expect do
          note.destroy
        end.to change(Fragment, :count).by(-1)

        expect(Fragment.exists?(fragment.id)).to be false
      end
    end
  end
end

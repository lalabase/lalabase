# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_uploads
#
#  id                 :uuid             not null, primary key
#  file_name          :string           not null
#  file_path          :string
#  linked_object_type :string           not null
#  processed          :boolean          default(FALSE)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  codebase_upload_id :string           not null
#  import_session_id  :string           not null
#  linked_object_id   :string           not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  idx_on_codebase_upload_id_organisation_id_d46c273408   (codebase_upload_id,organisation_id)
#  idx_on_linked_object_type_linked_object_id_88d5bd8833  (linked_object_type,linked_object_id)
#  index_codebase_uploads_on_import_session_id            (import_session_id)
#  index_codebase_uploads_on_organisation_id              (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

RSpec.describe CodebaseUpload, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------
  describe 'constants' do
    it 'defines LINKED_TYPE_TICKET_UPDATE' do
      expect(described_class::LINKED_TYPE_TICKET_UPDATE).to eq('Tickets::Update')
    end

    it 'defines LINKED_TYPE_PROJECT_FILE' do
      expect(described_class::LINKED_TYPE_PROJECT_FILE).to eq('ProjectFile')
    end

    it 'defines LINKED_TYPE_ACCOUNT' do
      expect(described_class::LINKED_TYPE_ACCOUNT).to eq('Account')
    end

    it 'defines LINKED_TYPES as frozen array of all types' do
      expect(described_class::LINKED_TYPES).to contain_exactly(
        'Tickets::Update', 'ProjectFile', 'Account'
      )
      expect(described_class::LINKED_TYPES).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to belong_to(:organisation).optional }
  end

  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------
  describe 'validations' do
    subject { build(:codebase_upload, organisation: organisation) }

    it { is_expected.to validate_presence_of(:codebase_upload_id) }
    it { is_expected.to validate_presence_of(:file_name) }
    it { is_expected.to validate_presence_of(:linked_object_type) }
    it { is_expected.to validate_presence_of(:linked_object_id) }
    it { is_expected.to validate_presence_of(:import_session_id) }

    it {
      is_expected.to validate_inclusion_of(:linked_object_type)
        .in_array(described_class::LINKED_TYPES)
    }

    it 'is valid with valid attributes' do
      upload = build(:codebase_upload, organisation: organisation)
      expect(upload).to be_valid
    end

    it 'is invalid with an unknown linked_object_type' do
      upload = build(:codebase_upload, organisation: organisation, linked_object_type: 'UnknownType')
      expect(upload).not_to be_valid
      expect(upload.errors[:linked_object_type]).to be_present
    end

    it 'is invalid with blank codebase_upload_id' do
      upload = build(:codebase_upload, organisation: organisation, codebase_upload_id: '')
      expect(upload).not_to be_valid
      expect(upload.errors[:codebase_upload_id]).to be_present
    end

    it 'is invalid with blank file_name' do
      upload = build(:codebase_upload, organisation: organisation, file_name: '')
      expect(upload).not_to be_valid
      expect(upload.errors[:file_name]).to be_present
    end

    it 'is invalid with blank linked_object_id' do
      upload = build(:codebase_upload, organisation: organisation, linked_object_id: '')
      expect(upload).not_to be_valid
      expect(upload.errors[:linked_object_id]).to be_present
    end

    it 'is invalid with blank import_session_id' do
      upload = build(:codebase_upload, organisation: organisation, import_session_id: '')
      expect(upload).not_to be_valid
      expect(upload.errors[:import_session_id]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # Default values
  # ---------------------------------------------------------------------------
  describe 'default values' do
    it 'defaults processed to false' do
      upload = described_class.new
      expect(upload.processed).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  describe 'scopes' do
    let!(:ticket_upload) do
      create(:codebase_upload, :ticket_upload, organisation: organisation, processed: false)
    end
    let!(:project_file_upload) do
      create(:codebase_upload, :project_file, organisation: organisation, processed: true)
    end
    let!(:account_upload) do
      create(:codebase_upload, :account_file, organisation: organisation, processed: false)
    end

    describe '.ticket_uploads' do
      it 'returns only ticket update uploads' do
        expect(described_class.ticket_uploads).to contain_exactly(ticket_upload)
      end

      it 'excludes project file and account uploads' do
        result = described_class.ticket_uploads
        expect(result).not_to include(project_file_upload, account_upload)
      end
    end

    describe '.project_file_uploads' do
      it 'returns only project file uploads' do
        expect(described_class.project_file_uploads).to contain_exactly(project_file_upload)
      end

      it 'excludes ticket and account uploads' do
        result = described_class.project_file_uploads
        expect(result).not_to include(ticket_upload, account_upload)
      end
    end

    describe '.unprocessed' do
      it 'returns only unprocessed uploads' do
        expect(described_class.unprocessed).to contain_exactly(ticket_upload, account_upload)
      end

      it 'excludes processed uploads' do
        expect(described_class.unprocessed).not_to include(project_file_upload)
      end
    end

    describe '.processed' do
      it 'returns only processed uploads' do
        expect(described_class.processed).to contain_exactly(project_file_upload)
      end

      it 'excludes unprocessed uploads' do
        expect(described_class.processed).not_to include(ticket_upload, account_upload)
      end
    end

    describe '.for_session' do
      it 'returns uploads matching the given session id' do
        session_id = ticket_upload.import_session_id
        expect(described_class.for_session(session_id)).to contain_exactly(ticket_upload)
      end

      it 'returns empty when no uploads match the session id' do
        expect(described_class.for_session('nonexistent_session')).to be_empty
      end

      it 'returns multiple uploads for the same session' do
        shared_session = 'shared_session_123'
        upload_a = create(:codebase_upload, organisation: organisation, import_session_id: shared_session)
        upload_b = create(:codebase_upload, organisation: organisation, import_session_id: shared_session)

        expect(described_class.for_session(shared_session)).to contain_exactly(upload_a, upload_b)
      end
    end

    describe 'scope chaining' do
      it 'combines ticket_uploads and unprocessed' do
        expect(described_class.ticket_uploads.unprocessed).to contain_exactly(ticket_upload)
      end

      it 'combines processed and project_file_uploads' do
        expect(described_class.processed.project_file_uploads).to contain_exactly(project_file_upload)
      end

      it 'returns empty when combining non-overlapping scopes' do
        expect(described_class.ticket_uploads.processed).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Instance methods: type checks
  # ---------------------------------------------------------------------------
  describe '#ticket_update?' do
    it 'returns true for Tickets::Update type' do
      upload = build(:codebase_upload, :ticket_upload, organisation: organisation)
      expect(upload.ticket_update?).to be true
    end

    it 'returns false for ProjectFile type' do
      upload = build(:codebase_upload, :project_file, organisation: organisation)
      expect(upload.ticket_update?).to be false
    end

    it 'returns false for Account type' do
      upload = build(:codebase_upload, :account_file, organisation: organisation)
      expect(upload.ticket_update?).to be false
    end
  end

  describe '#project_file?' do
    it 'returns true for ProjectFile type' do
      upload = build(:codebase_upload, :project_file, organisation: organisation)
      expect(upload.project_file?).to be true
    end

    it 'returns false for Tickets::Update type' do
      upload = build(:codebase_upload, :ticket_upload, organisation: organisation)
      expect(upload.project_file?).to be false
    end

    it 'returns false for Account type' do
      upload = build(:codebase_upload, :account_file, organisation: organisation)
      expect(upload.project_file?).to be false
    end
  end

  describe '#account_file?' do
    it 'returns true for Account type' do
      upload = build(:codebase_upload, :account_file, organisation: organisation)
      expect(upload.account_file?).to be true
    end

    it 'returns false for Tickets::Update type' do
      upload = build(:codebase_upload, :ticket_upload, organisation: organisation)
      expect(upload.account_file?).to be false
    end

    it 'returns false for ProjectFile type' do
      upload = build(:codebase_upload, :project_file, organisation: organisation)
      expect(upload.account_file?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Instance methods: file_exists?
  # ---------------------------------------------------------------------------
  describe '#file_exists?' do
    it 'returns false when file_path is nil' do
      upload = build(:codebase_upload, organisation: organisation, file_path: nil)
      expect(upload.file_exists?).to be false
    end

    it 'returns false when file_path is blank' do
      upload = build(:codebase_upload, organisation: organisation, file_path: '')
      expect(upload.file_exists?).to be false
    end

    it 'returns false when file_path points to a non-existent file' do
      upload = build(:codebase_upload, organisation: organisation, file_path: '/tmp/nonexistent_file_xyz.txt')
      expect(upload.file_exists?).to be false
    end

    it 'returns true when file_path points to an existing file' do
      tmpfile = Tempfile.new('codebase_upload_test')
      begin
        upload = build(:codebase_upload, organisation: organisation, file_path: tmpfile.path)
        expect(upload.file_exists?).to be true
      ensure
        tmpfile.close
        tmpfile.unlink
      end
    end

    it 'returns false after an existing file is deleted' do
      tmpfile = Tempfile.new('codebase_upload_test')
      path = tmpfile.path
      tmpfile.close
      tmpfile.unlink

      upload = build(:codebase_upload, organisation: organisation, file_path: path)
      expect(upload.file_exists?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Instance methods: mark_as_processed!
  # ---------------------------------------------------------------------------
  describe '#mark_as_processed!' do
    it 'sets processed to true and persists' do
      upload = create(:codebase_upload, organisation: organisation, processed: false)
      upload.mark_as_processed!

      expect(upload.processed).to be true
      expect(upload.reload.processed).to be true
    end

    it 'is idempotent when already processed' do
      upload = create(:codebase_upload, :processed, organisation: organisation)
      expect { upload.mark_as_processed! }.not_to raise_error
      expect(upload.reload.processed).to be true
    end

    it 'updates the updated_at timestamp' do
      upload = create(:codebase_upload, organisation: organisation)
      original_updated_at = upload.updated_at

      travel_to(1.minute.from_now) do
        upload.mark_as_processed!
        expect(upload.reload.updated_at).to be > original_updated_at
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-tenancy
  # ---------------------------------------------------------------------------
  describe 'multi-tenancy' do
    let(:other_organisation) { create(:organisation) }

    it 'scopes queries to the current tenant' do
      upload = create(:codebase_upload, organisation: organisation)

      ActsAsTenant.without_tenant do
        create(:codebase_upload, organisation: other_organisation)
      end

      ActsAsTenant.current_tenant = organisation
      expect(described_class.all).to contain_exactly(upload)
    end

    it 'prevents access to other tenant records' do
      ActsAsTenant.without_tenant do
        create(:codebase_upload, organisation: other_organisation)
      end

      ActsAsTenant.current_tenant = organisation
      expect(described_class.count).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Factory traits
  # ---------------------------------------------------------------------------
  describe 'factory' do
    it 'creates a valid default record' do
      upload = create(:codebase_upload, organisation: organisation)
      expect(upload).to be_persisted
      expect(upload.processed).to be false
      expect(upload.linked_object_type).to eq(described_class::LINKED_TYPE_TICKET_UPDATE)
    end

    it 'creates a valid processed record' do
      upload = create(:codebase_upload, :processed, organisation: organisation)
      expect(upload.processed).to be true
    end

    it 'creates valid records for each type trait' do
      %i[ticket_upload project_file account_file].each do |trait|
        upload = create(:codebase_upload, trait, organisation: organisation)
        expect(upload).to be_persisted
      end
    end

    it 'generates unique codebase_upload_ids via sequence' do
      upload_a = create(:codebase_upload, organisation: organisation)
      upload_b = create(:codebase_upload, organisation: organisation)
      expect(upload_a.codebase_upload_id).not_to eq(upload_b.codebase_upload_id)
    end

    it 'generates unique linked_object_ids via sequence' do
      upload_a = create(:codebase_upload, organisation: organisation)
      upload_b = create(:codebase_upload, organisation: organisation)
      expect(upload_a.linked_object_id).not_to eq(upload_b.linked_object_id)
    end
  end
end

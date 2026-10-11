# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::UploadAssignmentService, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, memberships: [create(:membership, organisation: organisation)]) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:post_record) { create(:post, ticket: ticket, organisation: organisation) }

  let(:upload_import_file) do
    create(:codebase_import_file,
           organisation: organisation,
           project: project,
           user: user,
           file_type: 'uploads',
           status: 'processed')
  end

  let(:temp_dir) { Rails.root.join('tmp/test_uploads') }
  let(:update_id) { '12345' }

  let(:upload_data) do
    [{
      id: '1',
      file_name: 'test.txt',
      identifier: 'abc123',
      linked_object_type: 'Tickets::Update',
      linked_object_id: update_id
    }]
  end

  subject(:service) do
    described_class.new(
      organisation: organisation,
      project: project,
      user: user,
      upload_import_file: upload_import_file
    )
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  # --- Helper: Setup temp dir + file, skip archive extraction ---
  def setup_temp_file(identifier: 'abc123', file_name: 'test.txt', content: 'Test file content')
    FileUtils.mkdir_p(temp_dir.join(identifier))
    File.write(temp_dir.join(identifier, file_name), content)

    allow_any_instance_of(described_class).to receive(:extract_tar_files) do |svc|
      svc.instance_variable_set(:@temp_dir, temp_dir)
    end
  end

  def create_imported_object_for_post(post, original_id:)
    ImportedObject.create!(
      organisation: organisation,
      importable: post,
      import_session_id: 'test-session',
      import_source: 'codebase_hq',
      imported_at: Time.current,
      metadata: { 'original_id' => original_id.to_s }
    )
  end

  # =========================================================================
  # #call — Happy Path
  # =========================================================================
  describe '#call' do
    context 'when everything matches (happy path)' do
      before do
        create_imported_object_for_post(post_record, original_id: update_id)
        allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
        setup_temp_file
      end

      it 'creates a PostDocument attached to the matching post' do
        expect { service.call }.to change(PostDocument, :count).by(1)

        post_document = PostDocument.last
        expect(post_document.post).to eq(post_record)
        expect(post_document.post_document_file).to be_attached
        expect(post_document.post_document_file.filename.to_s).to eq('test.txt')
        expect(post_document.create_embeddings).to be false
      end

      it 'creates a CodebaseUpload tracking record' do
        expect { service.call }.to change(CodebaseUpload, :count).by(1)

        tracking = CodebaseUpload.last
        expect(tracking.codebase_upload_id).to eq('1')
        expect(tracking.file_name).to eq('test.txt')
        expect(tracking.linked_object_type).to eq('Tickets::Update')
        expect(tracking.linked_object_id).to eq(update_id)
        expect(tracking.processed).to be true
      end

      it 'returns success hash with assignment results' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(1)
        expect(result[:errors]).to be_empty
        expect(result[:results]).to include(
          hash_including(
            upload_id: '1',
            post_id: post_record.id,
            ticket_id: ticket.id,
            file_name: 'test.txt',
            success: true
          )
        )
      end
    end

    # =========================================================================
    # #call — Multiple Uploads
    # =========================================================================
    context 'with multiple uploads' do
      let(:ticket2) { create(:ticket, project: project, organisation: organisation) }
      let(:post2) { create(:post, ticket: ticket2, organisation: organisation) }

      let(:multi_upload_data) do
        [
          { id: '1', file_name: 'doc1.txt', identifier: 'aaa', linked_object_type: 'Tickets::Update', linked_object_id: '100' },
          { id: '2', file_name: 'doc2.txt', identifier: 'bbb', linked_object_type: 'Tickets::Update', linked_object_id: '200' }
        ]
      end

      before do
        create_imported_object_for_post(post_record, original_id: '100')
        create_imported_object_for_post(post2, original_id: '200')
        allow(upload_import_file).to receive(:parsed_data).and_return(multi_upload_data)

        FileUtils.mkdir_p(temp_dir.join('aaa'))
        FileUtils.mkdir_p(temp_dir.join('bbb'))
        File.write(temp_dir.join('aaa', 'doc1.txt'), 'Content 1')
        File.write(temp_dir.join('bbb', 'doc2.txt'), 'Content 2')

        allow_any_instance_of(described_class).to receive(:extract_tar_files) do |svc|
          svc.instance_variable_set(:@temp_dir, temp_dir)
        end
      end

      it 'processes all uploads and creates PostDocuments for each' do
        # ActiveStorage attaches files per-record; this loop's repeated
        # `active_storage_attachments` lookup is inherent, not a real N+1.
        Prosopite.pause
        begin
          expect { service.call }.to change(PostDocument, :count).by(2)
        ensure
          Prosopite.resume
        end
      end

      it 'returns correct processed_count' do
        Prosopite.pause
        begin
          result = service.call
          expect(result[:processed_count]).to eq(2)
          expect(result[:errors]).to be_empty
        ensure
          Prosopite.resume
        end
      end
    end

    # =========================================================================
    # #call — Mixed success/failure
    # =========================================================================
    context 'with mixed success and failure uploads' do
      let(:mixed_data) do
        [
          { id: '1', file_name: 'good.txt', identifier: 'aaa', linked_object_type: 'Tickets::Update', linked_object_id: update_id },
          { id: '2', file_name: 'orphan.txt', identifier: 'bbb', linked_object_type: 'Tickets::Update', linked_object_id: 'nonexistent' }
        ]
      end

      before do
        create_imported_object_for_post(post_record, original_id: update_id)
        allow(upload_import_file).to receive(:parsed_data).and_return(mixed_data)
        setup_temp_file(identifier: 'aaa', file_name: 'good.txt')
      end

      it 'processes the valid upload and records the error for the invalid one' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(1)
        expect(result[:errors].size).to eq(1)
        expect(result[:errors].first[:upload_id]).to eq('2')
      end
    end

    # =========================================================================
    # #call — No matching posts
    # =========================================================================
    context 'when no matching post exists for update_id' do
      before do
        allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
        allow_any_instance_of(described_class).to receive(:extract_tar_files)
      end

      it 'does not create PostDocument' do
        expect { service.call }.not_to change(PostDocument, :count)
      end

      it 'records error for missing post' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:errors]).to include(
          hash_including(
            upload_id: '1',
            error: "Post not found for update ID: #{update_id}"
          )
        )
      end
    end

    # =========================================================================
    # #call — Physical file missing
    # =========================================================================
    context 'when physical file does not exist' do
      before do
        create_imported_object_for_post(post_record, original_id: update_id)
        allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)

        # Setup temp dir but WITHOUT creating the file
        FileUtils.mkdir_p(temp_dir)
        allow_any_instance_of(described_class).to receive(:extract_tar_files) do |svc|
          svc.instance_variable_set(:@temp_dir, temp_dir)
        end
      end

      it 'does not create PostDocument' do
        expect { service.call }.not_to change(PostDocument, :count)
      end

      it 'records error for missing file' do
        result = service.call

        expect(result[:errors]).to include(
          hash_including(
            upload_id: '1',
            error: 'Physical file not found: test.txt'
          )
        )
      end
    end

    # =========================================================================
    # #call — Non-ticket uploads are filtered out
    # =========================================================================
    context 'when uploads include non-ticket types' do
      let(:mixed_type_data) do
        [
          { id: '1', file_name: 'ticket.txt', identifier: 'aaa', linked_object_type: 'Tickets::Update', linked_object_id: update_id },
          { id: '2', file_name: 'project.txt', identifier: 'bbb', linked_object_type: 'ProjectFile', linked_object_id: '999' },
          { id: '3', file_name: 'account.txt', identifier: 'ccc', linked_object_type: 'Account', linked_object_id: '888' }
        ]
      end

      before do
        create_imported_object_for_post(post_record, original_id: update_id)
        allow(upload_import_file).to receive(:parsed_data).and_return(mixed_type_data)
        setup_temp_file(identifier: 'aaa', file_name: 'ticket.txt')
      end

      it 'only processes Tickets::Update uploads' do
        result = service.call

        expect(result[:processed_count]).to eq(1)
        expect(result[:results].first[:upload_id]).to eq('1')
      end
    end

    # =========================================================================
    # #call — Empty parsed_data
    # =========================================================================
    context 'when parsed_data is empty' do
      before do
        allow(upload_import_file).to receive(:parsed_data).and_return([])
        allow_any_instance_of(described_class).to receive(:extract_tar_files)
      end

      it 'returns success with zero processed' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(0)
        expect(result[:errors]).to be_empty
      end
    end

    context 'when parsed_data is nil' do
      before do
        allow(upload_import_file).to receive(:parsed_data).and_return(nil)
        allow_any_instance_of(described_class).to receive(:extract_tar_files)
      end

      it 'treats nil as empty array and returns success' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(0)
      end
    end

    # =========================================================================
    # #call — Wrong file_type
    # =========================================================================
    context 'when upload_import_file has wrong file_type' do
      let(:upload_import_file) do
        create(:codebase_import_file,
               organisation: organisation,
               project: project,
               user: user,
               file_type: 'tickets',
               status: 'processed')
      end

      it 'returns failure with invalid file type error' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid file type: tickets')
      end
    end

    # =========================================================================
    # #call — No archive file attached
    # =========================================================================
    context 'when no archive file is attached' do
      before do
        allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
        allow(upload_import_file).to receive(:archive_file).and_return(double(present?: false))
      end

      it 'skips extraction and still processes (files will be missing)' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:errors]).not_to be_empty
      end
    end

    # =========================================================================
    # #call — Timeout
    # =========================================================================
    context 'when processing times out' do
      before do
        allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)
      end

      it 'returns failure with timeout error' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to include('timed out')
      end

      it 'attempts cleanup' do
        expect_any_instance_of(described_class).to receive(:safe_cleanup)
        service.call
      end
    end

    # =========================================================================
    # #call — Unexpected error
    # =========================================================================
    context 'when an unexpected error occurs' do
      before do
        allow(upload_import_file).to receive(:parsed_data).and_raise(RuntimeError, 'Database exploded')
      end

      it 'returns failure with error message' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Database exploded')
      end

      it 'attempts cleanup' do
        expect_any_instance_of(described_class).to receive(:safe_cleanup)
        service.call
      end
    end

    # =========================================================================
    # #call — Error during single upload does not abort batch
    # =========================================================================
    context 'when attach_file_to_post raises on one upload' do
      let(:batch_data) do
        [
          { id: '1', file_name: 'fail.txt', identifier: 'aaa', linked_object_type: 'Tickets::Update', linked_object_id: '100' },
          { id: '2', file_name: 'good.txt', identifier: 'bbb', linked_object_type: 'Tickets::Update', linked_object_id: '200' }
        ]
      end

      let(:ticket2) { create(:ticket, project: project, organisation: organisation) }
      let(:post2) { create(:post, ticket: ticket2, organisation: organisation) }

      before do
        create_imported_object_for_post(post_record, original_id: '100')
        create_imported_object_for_post(post2, original_id: '200')
        allow(upload_import_file).to receive(:parsed_data).and_return(batch_data)

        FileUtils.mkdir_p(temp_dir.join('aaa'))
        FileUtils.mkdir_p(temp_dir.join('bbb'))
        File.write(temp_dir.join('aaa', 'fail.txt'), 'content')
        File.write(temp_dir.join('bbb', 'good.txt'), 'content')

        allow_any_instance_of(described_class).to receive(:extract_tar_files) do |svc|
          svc.instance_variable_set(:@temp_dir, temp_dir)
        end

        call_count = 0
        allow_any_instance_of(described_class).to receive(:attach_file_to_post).and_wrap_original do |method, *args|
          call_count += 1
          raise 'Disk full' if call_count == 1

          method.call(*args)
        end
      end

      it 'continues processing remaining uploads after error' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(1)
        expect(result[:errors].size).to eq(1)
        expect(result[:errors].first[:error]).to eq('Disk full')
      end
    end

    # =========================================================================
    # #call — Cleanup temp files
    # =========================================================================
    context 'temp file cleanup' do
      before do
        create_imported_object_for_post(post_record, original_id: update_id)
        allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
        setup_temp_file
      end

      it 'removes temp directory after successful processing' do
        service.call
        expect(Dir.exist?(temp_dir)).to be false
      end
    end
  end

  # =========================================================================
  # Private method: #find_post_by_update_id
  # =========================================================================
  describe '#find_post_by_update_id (via send)' do
    it 'returns post when imported_object matches and project matches' do
      create_imported_object_for_post(post_record, original_id: '999')
      result = service.send(:find_post_by_update_id, '999')
      expect(result).to eq(post_record)
    end

    it 'returns nil when imported_object exists but post belongs to different project' do
      other_project = create(:project, organisation: organisation)
      other_ticket = create(:ticket, project: other_project, organisation: organisation)
      other_post = create(:post, ticket: other_ticket, organisation: organisation)
      create_imported_object_for_post(other_post, original_id: '999')

      result = service.send(:find_post_by_update_id, '999')
      expect(result).to be_nil
    end

    it 'returns nil when no imported_object exists' do
      result = service.send(:find_post_by_update_id, 'nonexistent')
      expect(result).to be_nil
    end

    it 'returns nil when importable has been deleted (dangling reference)' do
      create_imported_object_for_post(post_record, original_id: '999')

      # Simulate dangling reference: delete the post without cascade
      Post.where(id: post_record.id).delete_all

      result = service.send(:find_post_by_update_id, '999')
      expect(result).to be_nil
    end

    it 'handles numeric update_id by converting to string' do
      create_imported_object_for_post(post_record, original_id: '42')
      result = service.send(:find_post_by_update_id, 42)
      expect(result).to eq(post_record)
    end
  end

  # =========================================================================
  # Private method: #find_physical_file
  # =========================================================================
  describe '#find_physical_file (via send)' do
    before do
      service.instance_variable_set(:@temp_dir, temp_dir)
      FileUtils.mkdir_p(temp_dir.join('abc123'))
    end

    it 'returns direct path when file exists at identifier/file_name' do
      File.write(temp_dir.join('abc123', 'test.txt'), 'content')
      result = service.send(:find_physical_file, 'abc123', 'test.txt')
      expect(result.to_s).to eq(temp_dir.join('abc123', 'test.txt').to_s)
    end

    it 'falls back to glob search when direct path not found' do
      FileUtils.mkdir_p(temp_dir.join('other_dir'))
      File.write(temp_dir.join('other_dir', 'test.txt'), 'content')

      result = service.send(:find_physical_file, 'wrong_identifier', 'test.txt')
      expect(result.to_s).to include('test.txt')
    end

    it 'returns nil when file does not exist anywhere' do
      result = service.send(:find_physical_file, 'abc123', 'nonexistent.txt')
      expect(result).to be_nil
    end

    it 'returns nil when temp_dir is nil' do
      service.instance_variable_set(:@temp_dir, nil)
      result = service.send(:find_physical_file, 'abc123', 'test.txt')
      expect(result).to be_nil
    end

    it 'sanitizes path traversal attempts in identifier' do
      File.write(temp_dir.join('abc123', 'test.txt'), 'content')
      result = service.send(:find_physical_file, '../../etc', 'passwd')
      # File.basename('../../etc') => 'etc', so it looks in temp_dir/etc/passwd
      expect(result).to be_nil
    end

    it 'sanitizes path traversal attempts in file_name' do
      result = service.send(:find_physical_file, 'abc123', '../../etc/passwd')
      # File.basename strips to 'passwd'
      expect(result).to be_nil
    end

    # File.basename leaves '..' and '.' as they are, so these survive the sanitising
    context 'with a name that basename passes through unchanged' do
      let(:outside_file) { temp_dir.dirname.join('outside_secret.txt') }

      before { File.write(outside_file, 'secret') }
      after { FileUtils.rm_f(outside_file) }

      it 'does not read a file one level above the extraction directory' do
        expect(service.send(:find_physical_file, '..', 'outside_secret.txt')).to be_nil
      end

      it 'does not return the extraction directory itself' do
        expect(service.send(:find_physical_file, 'abc123', '..')).to be_nil
      end

      it 'does not return the directory above it' do
        expect(service.send(:find_physical_file, '..', '..')).to be_nil
      end

      it 'does not return the identifier directory' do
        expect(service.send(:find_physical_file, 'abc123', '.')).to be_nil
      end
    end

    it 'skips a directory named like the file in the glob fallback' do
      # Dir.glob sorts, so the directory under 'a_dir' comes before the file under 'b_dir'
      FileUtils.mkdir_p(temp_dir.join('a_dir', 'report.txt'))
      FileUtils.mkdir_p(temp_dir.join('b_dir'))
      File.write(temp_dir.join('b_dir', 'report.txt'), 'content')

      result = service.send(:find_physical_file, 'wrong_identifier', 'report.txt')
      expect(result.to_s).to eq(temp_dir.join('b_dir', 'report.txt').to_s)
    end
  end

  # =========================================================================
  # An uploads.xml that names a file outside the extraction directory
  # =========================================================================
  describe 'uploads.xml pointing above the extraction directory' do
    let(:outside_file) { temp_dir.dirname.join('outside_secret.txt') }
    let(:upload_data) do
      [{ id: '1', file_name: 'outside_secret.txt', identifier: '..',
         linked_object_type: 'Tickets::Update', linked_object_id: update_id }]
    end

    before do
      File.write(outside_file, 'secret')
      setup_temp_file
      allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
      create_imported_object_for_post(post_record, original_id: update_id)
    end

    after { FileUtils.rm_f(outside_file) }

    it 'attaches nothing and reports the file as missing' do
      result = nil
      expect { result = service.call }.not_to change(PostDocument, :count)

      expect(result[:errors].pluck(:error)).to eq(['Physical file not found: outside_secret.txt'])
    end
  end

  # =========================================================================
  # Private method: #filter_ticket_uploads
  # =========================================================================
  describe '#filter_ticket_uploads (via send)' do
    it 'returns only Tickets::Update entries' do
      data = [
        { id: '1', linked_object_type: 'Tickets::Update' },
        { id: '2', linked_object_type: 'ProjectFile' },
        { id: '3', linked_object_type: 'Account' },
        { id: '4', linked_object_type: 'Tickets::Update' }
      ]

      result = service.send(:filter_ticket_uploads, data)
      expect(result.map { |u| u[:id] }).to eq(%w[1 4])
    end

    it 'returns empty array when no ticket uploads exist' do
      data = [
        { id: '1', linked_object_type: 'ProjectFile' },
        { id: '2', linked_object_type: 'Account' }
      ]

      result = service.send(:filter_ticket_uploads, data)
      expect(result).to be_empty
    end

    it 'returns empty array for empty input' do
      expect(service.send(:filter_ticket_uploads, [])).to be_empty
    end
  end

  # =========================================================================
  # Private method: #parse_uploads_xml
  # =========================================================================
  describe '#parse_uploads_xml (via send)' do
    it 'returns parsed_data when file_type is uploads' do
      allow(upload_import_file).to receive(:parsed_data).and_return([{ id: '1' }])
      result = service.send(:parse_uploads_xml)
      expect(result).to eq([{ id: '1' }])
    end

    it 'returns empty array when parsed_data is nil' do
      allow(upload_import_file).to receive(:parsed_data).and_return(nil)
      result = service.send(:parse_uploads_xml)
      expect(result).to eq([])
    end

    it 'raises error when file_type is not uploads' do
      wrong_file = create(:codebase_import_file,
                          organisation: organisation,
                          user: user,
                          file_type: 'tickets')
      wrong_service = described_class.new(
        organisation: organisation,
        project: project,
        user: user,
        upload_import_file: wrong_file
      )

      expect { wrong_service.send(:parse_uploads_xml) }.to raise_error(RuntimeError, /Invalid file type: tickets/)
    end
  end

  # =========================================================================
  # Private method: #generate_assignment_session_id
  # =========================================================================
  describe '#generate_assignment_session_id (via send)' do
    it 'generates deterministic session id containing project id' do
      result = service.send(:generate_assignment_session_id)
      expect(result).to start_with("upload_assignment_#{project.id}_")
    end

    it 'memoizes the session id across calls' do
      first = service.send(:generate_assignment_session_id)
      second = service.send(:generate_assignment_session_id)
      expect(first).to eq(second)
    end
  end

  # =========================================================================
  # Private method: #track_upload_assignment
  # =========================================================================
  describe '#track_upload_assignment (via send)' do
    let(:data) do
      { id: 'cb-1', file_name: 'doc.pdf', linked_object_type: 'Tickets::Update', linked_object_id: '555' }
    end

    it 'creates a CodebaseUpload with correct attributes' do
      expect do
        service.send(:track_upload_assignment, data)
      end.to change(CodebaseUpload, :count).by(1)

      record = CodebaseUpload.last
      expect(record.codebase_upload_id).to eq('cb-1')
      expect(record.file_name).to eq('doc.pdf')
      expect(record.linked_object_type).to eq('Tickets::Update')
      expect(record.linked_object_id).to eq('555')
      expect(record.organisation).to eq(organisation)
      expect(record.processed).to be true
    end
  end

  # =========================================================================
  # TIMEOUT_SECONDS constant
  # =========================================================================
  describe 'TIMEOUT_SECONDS' do
    it 'is defined as 600 seconds (10 minutes)' do
      expect(described_class::TIMEOUT_SECONDS).to eq(600)
    end
  end

  # =========================================================================
  # ZIP extraction with a real archive (nothing stubbed)
  # =========================================================================
  describe 'ZIP archive extraction' do
    let(:extract_root) { Rails.root.join('tmp/uploads_extract') }
    let(:archive) do
      Zip::OutputStream.write_buffer do |zip|
        # Written without directory entries on purpose: the parent has to be created by hand
        zip.put_next_entry('abc123/test.txt')
        zip.write('Test file content')
        # The CVE-2026-85396 shape: climbs into a sibling of the extraction root
        zip.put_next_entry('../owned.txt')
        zip.write('owned')
        # The same climb through a directory: the mkdir_p ahead of the extract must not create it
        zip.put_next_entry('../evil/owned.txt')
        zip.write('owned')
      end.string
    end

    def remove_escaped_files
      FileUtils.rm_f(extract_root.join('owned.txt'))
      FileUtils.rm_rf(extract_root.join('evil'))
    end

    before do
      remove_escaped_files
      upload_import_file.archive_file.attach(io: StringIO.new(archive), filename: 'uploads.zip',
                                             content_type: 'application/zip')
      allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
      create_imported_object_for_post(post_record, original_id: update_id)
    end

    after { remove_escaped_files }

    it 'extracts the file and attaches it to the post' do
      expect { service.call }.to change(PostDocument, :count).by(1)

      expect(PostDocument.last.post_document_file.filename.to_s).to eq('test.txt')
    end

    it 'leaves entries that climb out of the extraction root unwritten' do
      result = service.call

      expect(result[:success]).to be(true)
      expect(File.exist?(extract_root.join('owned.txt'))).to be(false)
      expect(Dir.exist?(extract_root.join('evil'))).to be(false)
    end

    it 'reports each skipped entry as an error' do
      expect(service.call[:errors].pluck(:archive_entry)).to contain_exactly('../owned.txt', '../evil/owned.txt')
    end
  end

  # =========================================================================
  # TAR extraction with a real archive (nothing stubbed)
  # =========================================================================
  describe 'TAR archive extraction' do
    let(:extract_root) { Rails.root.join('tmp/uploads_extract') }
    # Absolute entry names are taken literally by Pathname#join, so this one
    # would land exactly here without the check
    let(:absolute_target) { Rails.root.join('tmp/tar_absolute_escape.txt').to_s }
    # Longer than the 100-byte name field, so TarWriter moves the ../ into the ustar
    # prefix: only full_name sees it, header.name alone reads a harmless 'escape.txt'
    let(:long_dir) { 'a' * 120 }
    let(:long_name) { "../#{long_dir}/escape.txt" }
    let(:archive) do
      io = StringIO.new
      Gem::Package::TarWriter.new(io) do |tar|
        tar.add_file_simple('abc123/test.txt', 0o644, 17) { |f| f.write('Test file content') }
        # Gem::Package::TarReader hands both names over unchanged
        tar.add_file_simple('../escape.txt', 0o644, 5) { |f| f.write('owned') }
        tar.add_file_simple('../evil/escape.txt', 0o644, 5) { |f| f.write('owned') }
        tar.add_file_simple(absolute_target, 0o644, 5) { |f| f.write('owned') }
        tar.add_file_simple(long_name, 0o644, 5) { |f| f.write('owned') }
      end
      io.string
    end

    def remove_escaped_files
      FileUtils.rm_f(extract_root.join('escape.txt'))
      FileUtils.rm_rf(extract_root.join('evil'))
      FileUtils.rm_rf(extract_root.join(long_dir))
      FileUtils.rm_f(absolute_target)
    end

    before do
      remove_escaped_files
      upload_import_file.archive_file.attach(io: StringIO.new(archive), filename: 'uploads.tar',
                                             content_type: 'application/x-tar')
      allow(upload_import_file).to receive(:parsed_data).and_return(upload_data)
      create_imported_object_for_post(post_record, original_id: update_id)
    end

    after { remove_escaped_files }

    it 'extracts the valid entry and attaches it to the post' do
      expect { service.call }.to change(PostDocument, :count).by(1)

      expect(PostDocument.last.post_document_file.filename.to_s).to eq('test.txt')
    end

    it 'leaves entries that climb out of the extraction root unwritten' do
      result = service.call

      expect(result[:success]).to be(true)
      expect(File.exist?(extract_root.join('escape.txt'))).to be(false)
      expect(Dir.exist?(extract_root.join('evil'))).to be(false)
      expect(Dir.exist?(extract_root.join(long_dir))).to be(false)
      expect(File.exist?(absolute_target)).to be(false)
    end

    it 'reports each skipped entry as an error' do
      result = service.call

      # The absolute name is not skipped: File.join nests it inside the extraction root
      expect(result[:errors].pluck(:archive_entry)).to contain_exactly('../escape.txt', '../evil/escape.txt', long_name)
    end

    # Keeps the extraction directory after the run and pins its name, so the examples can
    # look at what was written where and aim an entry at a sibling sharing its prefix
    context 'when looking at the extraction directory afterwards' do
      let(:root_name) { 'tarroot0123456789' }
      let(:kept_root) { extract_root.join(root_name) }
      let(:sibling) { extract_root.join("#{root_name}-evil") }
      let(:archive) do
        io = StringIO.new
        Gem::Package::TarWriter.new(io) do |tar|
          tar.add_file_simple('abc123/test.txt', 0o644, 17) { |f| f.write('Test file content') }
          tar.add_file_simple(absolute_target, 0o644, 5) { |f| f.write('owned') }
          # Starts with the root's path but is not inside it: only the separator in the
          # prefix check tells the two apart
          tar.add_file_simple("../#{root_name}-evil/escape.txt", 0o644, 5) { |f| f.write('owned') }
          # A link entry is not a file: written, it would point a later write elsewhere
          tar.add_symlink('abc123/link', '/etc/passwd', 0o777)
        end
        io.string
      end

      before do
        allow(SecureRandom).to receive(:hex).and_call_original
        allow(SecureRandom).to receive(:hex).with(8).and_return(root_name)
        allow(service).to receive(:cleanup_temp_files)
      end

      after do
        FileUtils.rm_rf(kept_root)
        FileUtils.rm_rf(sibling)
      end

      it 'writes the valid entry inside the root' do
        service.call

        expect(File.read(kept_root.join('abc123/test.txt'))).to eq('Test file content')
      end

      it 'nests an absolute entry name inside the root' do
        service.call

        expect(File.read(File.join(kept_root, absolute_target))).to eq('owned')
      end

      it 'refuses a sibling directory that shares the root prefix' do
        result = service.call

        expect(Dir.exist?(sibling)).to be(false)
        expect(result[:errors].pluck(:archive_entry)).to eq(["../#{root_name}-evil/escape.txt"])
      end

      it 'writes nothing for a symlink entry' do
        service.call

        expect(File.exist?(kept_root.join('abc123/link')) || File.symlink?(kept_root.join('abc123/link'))).to be(false)
      end
    end
  end
end

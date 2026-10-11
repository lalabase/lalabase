# frozen_string_literal: true

require 'rails_helper'

# The stock this exists for: BMP files that lost their thumbnail because libvips reaches BMP
# only through the ImageMagick delegation Rails 8.0.5.1 blocks (CVE-2026-66066).
RSpec.describe BmpAttachmentConversion do
  let(:organisation) { create(:organisation) }
  let(:bmp_bytes) { Rails.root.join('spec/fixtures/files/test_image.bmp').binread }
  let(:backup_dir) { Rails.root.join('tmp/bmp_backup_spec', SecureRandom.hex(4)) }

  # Fixture construction is paused for prosopite (spec/support/prosopite.rb scans every
  # example), so what gets scanned is the service, not the building of its input.
  def bmp_document(filename: 'screenshot.bmp', bytes: bmp_bytes)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        document = build(:post_document, organisation: organisation)
        document.post_document_file.attach(
          io: StringIO.new(bytes), filename: filename, content_type: 'image/bmp'
        )
        document.save!
        document
      end
    end
  end

  after { FileUtils.rm_rf(backup_dir) }

  describe 'the dry run' do
    it 'reports what it would do without touching the attachment' do
      document = bmp_document
      original_blob_id = document.reload.post_document_file.blob.id

      result = described_class.call(dry_run: true, backup_dir: backup_dir.to_s)

      expect(result.dry_run).to be(true)
      expect(result.scanned).to eq(1)
      expect(result.converted).to eq(1)
      expect(result.failed).to eq(0)
      expect(document.reload.post_document_file.blob.id).to eq(original_blob_id)
      expect(document.post_document_file.blob.content_type).to eq('image/bmp')
    end

    it 'writes nothing into the backup directory' do
      bmp_document

      described_class.call(dry_run: true, backup_dir: backup_dir.to_s)

      expect(backup_dir).not_to exist
    end

    # The point of converting in memory: the sizes are measured, not guessed, so the report
    # is worth reading before the real run.
    it 'measures the real sizes rather than estimating them' do
      bmp_document

      result = described_class.call(dry_run: true, backup_dir: backup_dir.to_s)

      expect(result.bytes_before).to eq(bmp_bytes.bytesize)
      expect(result.bytes_after).to be > 0
      expect(result.bytes_saved).to eq(result.bytes_before - result.bytes_after)
    end
  end

  describe 'the real run' do
    it 'replaces the attachment with a PNG' do
      document = bmp_document

      described_class.call(dry_run: false, backup_dir: backup_dir.to_s)

      blob = document.reload.post_document_file.blob
      expect(blob.content_type).to eq('image/png')
      expect(blob.filename.to_s).to eq('screenshot.png')
      expect(blob.download[0, 8].unpack1('H*')).to eq('89504e470d0a1a0a') # PNG signature
    end

    it 'keeps the original file in the backup directory' do
      bmp_document

      described_class.call(dry_run: false, backup_dir: backup_dir.to_s)

      backups = Dir.children(backup_dir)
      expect(backups.size).to eq(1)
      expect(backup_dir.join(backups.first).binread).to eq(bmp_bytes)
    end

    it 'leaves the converted attachment variable again' do
      document = bmp_document

      described_class.call(dry_run: false, backup_dir: backup_dir.to_s)

      expect(document.reload.post_document_file.blob.variable?).to be(true)
    end
  end

  describe 'a file that cannot be converted' do
    it 'counts it as failed, converts nothing and leaves the attachment alone' do
      document = bmp_document(filename: 'broken.bmp', bytes: 'this is not a bitmap')
      original_blob_id = document.reload.post_document_file.blob.id

      result = described_class.call(dry_run: false, backup_dir: backup_dir.to_s)

      expect(result.failed).to eq(1)
      expect(result.converted).to eq(0)
      expect(result.notes.first).to include('broken.bmp')
      expect(document.reload.post_document_file.blob.id).to eq(original_blob_id)
    end
  end

  describe 'limits and scope' do
    it 'honours the limit' do
      2.times { bmp_document }

      result = described_class.call(dry_run: true, limit: 1, backup_dir: backup_dir.to_s)

      expect(result.scanned).to eq(1)
    end

    # Three documents in one scan: if the service looked its owner up per blob, prosopite
    # would fail this example. That is the guard for the preload in #each_blob.
    it 'walks the whole stock without a query per attachment' do
      3.times { bmp_document }

      result = described_class.call(dry_run: true, backup_dir: backup_dir.to_s)

      expect(result.scanned).to eq(3)
      expect(result.converted).to eq(3)
    end

    it 'ignores attachments that are not BMP' do
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) { create(:post_document, organisation: organisation) }
      end

      result = described_class.call(dry_run: true, backup_dir: backup_dir.to_s)

      expect(result.scanned).to eq(0)
    end
  end
end

# frozen_string_literal: true

# One-off data conversion: rewrites BMP attachments as PNG. libvips has no BMP decoder of its
# own, it reaches the format only through its ImageMagick delegation, and Rails 8.0.5.1 blocks
# that delegation as untrusted (CVE-2026-66066). A BMP attachment therefore has no thumbnail
# any more, while the file itself stays downloadable. Converting the stock is the way back to
# previews that does NOT re-open that decoder for every future upload.
#
# Two deliberate choices:
#
# * The dry run converts for real, in memory, and only skips the writing. So it reports the
#   true sizes and it fails on a file that cannot be converted BEFORE anything is replaced.
# * The original is written to `backup_dir` before it is replaced. Attaching to a
#   has_one_attached association purges the previous blob, and these are customer documents.
#
# Runs across every tenant (ActsAsTenant.without_tenant), which is what an operations task
# needs and what application code must not do.
#
# Entry point: BmpAttachmentConversion.call(dry_run: true)
class BmpAttachmentConversion
  SOURCE_CONTENT_TYPE = 'image/bmp'
  TARGET_CONTENT_TYPE = 'image/png'
  TARGET_EXTENSION = '.png'
  DEFAULT_BACKUP_DIR = 'tmp/bmp_backup'

  Result = Struct.new(
    :dry_run, :scanned, :converted, :skipped, :failed,
    :bytes_before, :bytes_after, :notes,
    keyword_init: true
  ) do
    def bytes_saved
      bytes_before - bytes_after
    end
  end

  def self.call(dry_run: true, limit: nil, backup_dir: nil)
    new(dry_run: dry_run, limit: limit, backup_dir: backup_dir).call
  end

  def initialize(dry_run: true, limit: nil, backup_dir: nil)
    @dry_run = dry_run
    @limit = limit
    @backup_dir = Pathname.new(backup_dir.presence || Rails.root.join(DEFAULT_BACKUP_DIR))
    @scanned = 0
    @converted = 0
    @skipped = 0
    @failed = 0
    @bytes_before = 0
    @bytes_after = 0
    @notes = []
  end

  def call
    ActsAsTenant.without_tenant do
      each_blob { |blob| process(blob) }
    end

    Result.new(
      dry_run: dry_run, scanned: scanned, converted: converted, skipped: skipped, failed: failed,
      bytes_before: bytes_before, bytes_after: bytes_after, notes: notes
    )
  end

  private

  attr_reader :dry_run, :limit, :backup_dir, :scanned, :converted, :skipped, :failed,
              :bytes_before, :bytes_after, :notes

  # attachments and their records are preloaded: the task walks the whole stock in one go, and
  # looking the owner up per blob would be a textbook N+1 (guarded by prosopite in the spec).
  def each_blob(&)
    scope = ActiveStorage::Blob.where(content_type: SOURCE_CONTENT_TYPE)
                               .includes(attachments: :record)
                               .order(:created_at)
    scope = scope.limit(limit) if limit
    scope.each(&)
  end

  def process(blob)
    @scanned += 1

    record = owner_of(blob)
    return note_skip(blob, 'no PostDocument owns this blob') if record.nil?

    original = blob.download
    png = to_png(original)

    unless dry_run
      back_up(blob, original)
      replace(record, blob, png)
    end

    # Counted only once the write actually happened, so a partial failure never reports
    # a conversion that did not take place.
    @bytes_before += original.bytesize
    @bytes_after += png.bytesize
    @converted += 1
  rescue StandardError => e
    @failed += 1
    @notes << "FEHLER #{blob.id} #{blob.filename}: #{e.class}: #{e.message}"
  end

  # Only PostDocument is handled: it is where the whole BMP stock sits, and the attachment
  # name is known there. Anything else is reported instead of guessed at.
  def owner_of(blob)
    blob.attachments.find { |attachment| attachment.record_type == 'PostDocument' }&.record
  end

  def to_png(data)
    image = MiniMagick::Image.read(data)
    image.format('png')
    File.binread(image.path)
  end

  def back_up(blob, data)
    FileUtils.mkdir_p(backup_dir)
    backup_dir.join("#{blob.key}_#{blob.filename.sanitized}").binwrite(data)
  end

  def replace(record, blob, png)
    record.post_document_file.attach(
      io: StringIO.new(png),
      filename: "#{blob.filename.base}#{TARGET_EXTENSION}",
      content_type: TARGET_CONTENT_TYPE
    )
  end

  def note_skip(blob, reason)
    @skipped += 1
    @notes << "uebersprungen #{blob.id} #{blob.filename}: #{reason}"
  end
end

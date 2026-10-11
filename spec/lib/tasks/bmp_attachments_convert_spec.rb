# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake bmp_attachments:convert`, the one-time operations step that rewrites the BMP
#       attachments to PNG.
# Type: Rake task spec.
# Why:  The service next to it checks the numbers. Here we check the one promise that data
#       loss hangs on: WITHOUT APPLY=1 nothing is written. The other tasks in the project
#       are wired the other way round (live unless DRY_RUN=1), and exactly for that reason
#       this deviation must be a test and not a line in a comment.
RSpec.describe 'bmp_attachments:convert' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('bmp_attachments:convert')
  end

  let(:backup_dir) { Rails.root.join('tmp/bmp_backup_task_spec', SecureRandom.hex(4)) }

  before do
    Rake::Task['bmp_attachments:convert'].reenable
    ENV['BACKUP_DIR'] = backup_dir.to_s
  end

  after do
    ENV.delete('APPLY')
    ENV.delete('BACKUP_DIR')
    FileUtils.rm_rf(backup_dir)
  end

  let(:organisation) { create(:organisation) }
  let(:bmp_bytes) { Rails.root.join('spec/fixtures/files/test_image.bmp').binread }

  def bmp_document
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        document = build(:post_document, organisation: organisation)
        document.post_document_file.attach(
          io: StringIO.new(bmp_bytes), filename: 'screenshot.bmp', content_type: 'image/bmp'
        )
        document.save!
        document
      end
    end
  end

  it 'writes nothing when APPLY is unset' do
    document = bmp_document
    blob_id = document.reload.post_document_file.blob.id

    expect { Rake::Task['bmp_attachments:convert'].invoke }
      .to output(/Trockenlauf, nichts geschrieben/).to_stdout

    expect(document.reload.post_document_file.blob.id).to eq(blob_id)
    expect(document.post_document_file.blob.content_type).to eq('image/bmp')
  end

  it 'writes nothing when APPLY carries anything but 1' do
    ENV['APPLY'] = 'true'
    document = bmp_document
    blob_id = document.reload.post_document_file.blob.id

    expect { Rake::Task['bmp_attachments:convert'].invoke }
      .to output(/Trockenlauf/).to_stdout

    expect(document.reload.post_document_file.blob.id).to eq(blob_id)
  end

  it 'converts with APPLY=1 and says so' do
    ENV['APPLY'] = '1'
    document = bmp_document

    expect { Rake::Task['bmp_attachments:convert'].invoke }
      .to output(/scharf/).to_stdout

    expect(document.reload.post_document_file.blob.content_type).to eq('image/png')
  end

  it 'reports the counts the operator acts on' do
    bmp_document

    expect { Rake::Task['bmp_attachments:convert'].invoke }
      .to output(/gefunden:\s+1/).to_stdout
  end
end

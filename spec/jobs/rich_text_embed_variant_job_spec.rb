# frozen_string_literal: true

require 'rails_helper'

# What:  RichTextEmbedVariantJob pre-processes the inline display variant of a freshly
#        embedded image, so the first viewer gets a redirect instead of a vips run in
#        the Puma thread (spike plan Inline-Bilder, D8).
# Type:  Job spec (2026-08-23). Needs libvips (CI installs it; production has libvips42).
RSpec.describe RichTextEmbedVariantJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }
  let(:blob) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'shot.png', content_type: 'image/png') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'processes the display variant so the representation exists before the first view' do
    variant = blob.representation(resize_to_limit: RichTextEmbeds::DISPLAY_LIMIT)
    expect(variant.send(:processed?)).to be(false)

    described_class.perform_now(blob.id)

    expect(blob.reload.representation(resize_to_limit: RichTextEmbeds::DISPLAY_LIMIT).send(:processed?)).to be(true)
  end

  it 'is enqueued once per NEW embed when a carrier is saved, not for blobs already attached' do
    ActiveJob::Base.queue_adapter = :test
    html = %(<action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment>)
    ticket = create(:ticket, project: project, organisation: organisation, content: html)
    expect(described_class).to have_been_enqueued.with(blob.id).once

    clear_enqueued_jobs
    ticket.update!(content: "#{html}<div>mehr Text</div>")
    expect(described_class).not_to have_been_enqueued
  ensure
    ActiveJob::Base.queue_adapter = :solid_queue
  end

  it 'skips a non-image blob without raising' do
    pdf = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF-1.4 x'), filename: 'a.pdf', content_type: 'application/pdf')

    expect { described_class.perform_now(pdf.id) }.not_to raise_error
  end

  it 'discards a purged blob' do
    id = blob.id
    blob.purge

    expect { described_class.perform_now(id) }.not_to raise_error
  end
end

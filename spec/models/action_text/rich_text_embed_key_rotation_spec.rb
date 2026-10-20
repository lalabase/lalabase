# frozen_string_literal: true

require 'rails_helper'

# What:  Saving a rich text whose image nodes carry sgids signed with a previous
#        secret_key_base keeps those images attached.
# Type:  Model spec (2026-10-20).
# Why:   After a secret_key_base rotation no stored sgid resolves. Rails'
#        own before_validation rebuilds `embeds` from the sgids that resolve, so editing
#        only the words of such a text detached every image and enqueued the purge of its
#        file. RichTextEmbedRetention keeps a stored embed while the body still holds a
#        node it cannot resolve; the re-sign task (RichTextSgidResign) repairs the nodes.
RSpec.describe 'Rich text embeds across a secret_key_base rotation', :ci_guard do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  after { ActsAsTenant.current_tenant = nil }

  around do |example|
    verifier = SignedGlobalID.verifier
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
    SignedGlobalID.verifier = verifier
  end

  def png_blob(name = 'shot.png')
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 64}"), filename: name, content_type: 'image/png'
    )
  end

  def node(blob) = %(<action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment>)

  def rotate_secret_key_base!
    key = ActiveSupport::KeyGenerator.new('a-rotated-secret-key-base' * 4, iterations: 1000)
                                     .generate_key('signed_global_ids')
    SignedGlobalID.verifier = GlobalID::Verifier.new(key)
  end

  def embed_blob_ids(rich_text)
    ActiveStorage::Attachment.where(record: rich_text, name: 'embeds').pluck(:blob_id)
  end

  def purge_jobs
    enqueued_jobs.count { |job| job['job_class'] == 'ActiveStorage::PurgeJob' }
  end

  it 'keeps the images of a text whose words are edited after the rotation' do
    blob = png_blob
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>Schritt 1</div>#{node(blob)}")
    rotate_secret_key_base!
    ticket = Ticket.find(ticket.id)
    clear_enqueued_jobs

    ticket.update!(content: ticket.content.body.to_html.sub('Schritt 1', 'Schritt 1, ergänzt'))

    expect(embed_blob_ids(ticket.reload.content)).to eq([blob.id])
    expect(purge_jobs).to eq(0)
  end

  it 'still adds a new image next to the stale ones' do
    old_blob = png_blob('alt.png')
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(old_blob)}")
    rotate_secret_key_base!
    ticket = Ticket.find(ticket.id)
    new_blob = png_blob('neu.png')

    ticket.update!(content: ticket.content.body.to_html + node(new_blob))

    expect(embed_blob_ids(ticket.reload.content)).to contain_exactly(old_blob.id, new_blob.id)
  end

  # The retention is a safety net for nodes that cannot be read, not a second rule for
  # removing images: with every node resolving, Rails' own sync stays in charge.
  it 'still detaches an image that was removed from a text whose nodes all resolve' do
    kept = png_blob('bleibt.png')
    removed = png_blob('weg.png')
    ticket = create(:ticket, project: project, organisation: organisation,
                             content: "<div>x</div>#{node(kept)}#{node(removed)}")

    ticket.update!(content: "<div>x</div>#{node(kept)}")

    expect(embed_blob_ids(ticket.reload.content)).to eq([kept.id])
  end
end

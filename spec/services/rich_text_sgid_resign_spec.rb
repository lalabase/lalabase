# frozen_string_literal: true

require 'rails_helper'

# What:  RichTextSgidResign re-signs the attachment nodes of stored rich texts whose sgid
#        was signed with a previous secret_key_base, without that key.
# Type:  Service spec (2026-10-20).
# Why:   A secret_key_base rotation turns every stored image and wiki mention into a
#        "☒". A stale signature proves nothing, so a node is re-signed only when what the
#        app stored next to the text names the same target: an embed of this text for an
#        image, an outgoing reference of the note for a mention. A forged node, or one
#        that names anything else, must gain nothing. A Marshal payload is never loaded.
RSpec.describe RichTextSgidResign, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  after { ActsAsTenant.current_tenant = nil }

  around do |example|
    verifier = SignedGlobalID.verifier
    example.run
  ensure
    SignedGlobalID.verifier = verifier
  end

  def png_blob(name = 'shot.png')
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 64}"), filename: name, content_type: 'image/png'
    )
  end

  def node(record, extra = '')
    %(<action-text-attachment sgid="#{record.attachable_sgid}"#{extra}></action-text-attachment>)
  end

  def mention(note) = node(note, ' content-type="application/vnd.actiontext.mention"')

  # What a rotation does: the sgids written so far were signed with the key the
  # application booted with, every one minted from now on uses the new key.
  def rotate_secret_key_base!
    SignedGlobalID.verifier = GlobalID::Verifier.new(key_for('a-rotated-secret-key-base'))
  end

  def key_for(secret) = ActiveSupport::KeyGenerator.new(secret * 4, iterations: 1000).generate_key('signed_global_ids')

  # The self-describing metadata of older globalid releases, serialised with Marshal.
  def marshal_sgid(record)
    GlobalID::Verifier.new(key_for('an-old-secret-key-base'), serializer: Marshal)
                      .generate({ 'gid' => record.to_gid.to_s, 'purpose' => 'attachable', 'expires_at' => nil })
  end

  # A payload anybody can write: the current envelope with a made-up digest.
  def unsigned_sgid(record)
    payload = { _rails: { data: record.to_gid.to_s, pur: 'attachable' } }.to_json
    "#{Base64.urlsafe_encode64(payload)}--#{'0' * 40}"
  end

  def ticket_with_body(html)
    create(:ticket, project: project, organisation: organisation, content: '<div>x</div>').tap do |ticket|
      ticket.content.update_column(:body, html)
    end
  end

  def attach_embed(rich_text, blob) = ActiveStorage::Attachment.create!(record: rich_text, name: 'embeds', blob: blob)

  def sgids_of(record)
    Nokogiri::HTML.fragment(record.reload.content.body.to_html).css('action-text-attachment').map { |n| n['sgid'] }
  end

  def resolves?(sgid)
    ActionText::Attachable.from_attachable_sgid(sgid).present?
  rescue ActiveRecord::RecordNotFound
    false
  end

  def run(dry_run: false) = described_class.call(dry_run: dry_run)

  it 'brings back an image of the text and renders it instead of the glyph' do
    blob = png_blob
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>Schritt 1</div>#{node(blob)}")
    rotate_secret_key_base!
    expect(Ticket.find(ticket.id).content.to_s).to include('☒')

    expect(run.resigned).to eq(1)
    expect(sgids_of(ticket)).to all(satisfy { |sgid| resolves?(sgid) })
    expect(Ticket.find(ticket.id).content.to_s).not_to include('☒')
  end

  it 'reports without writing in dry run' do
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(png_blob)}")
    stale = sgids_of(ticket)
    rotate_secret_key_base!

    expect(run(dry_run: true).to_h).to include(changed: 1, resigned: 1, dry_run: true)
    expect(sgids_of(ticket)).to eq(stale)
  end

  it 'leaves nodes that already resolve alone and is idempotent' do
    create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(png_blob)}")
    rotate_secret_key_base!
    run

    expect(run.to_h).to include(changed: 0, resigned: 0)
  end

  it 'brings back a wiki mention the note references and re-derives the markdown body' do
    target = create(:note, project: project, organisation: organisation, title: 'Zielnotiz')
    note = create(:note, project: project, organisation: organisation, content: "<div>Siehe</div>#{mention(target)}")
    rotate_secret_key_base!
    note.update_column(:markdown_body, 'stale')

    expect(run.resigned).to eq(1)
    expect(resolves?(sgids_of(note).first)).to be(true)
    expect(note.reload.markdown_body).to eq(Wiki::MarkdownSerializer.new.to_markdown(note.content.body.to_html))
  end

  it 'refuses a mention the note does not reference, even within the organisation' do
    target = create(:note, project: project, organisation: organisation, title: 'Nie verlinkt')
    note = create(:note, project: project, organisation: organisation, content: '<div>x</div>')
    note.content.update_column(:body, "<div>x</div>#{mention(target)}")
    rotate_secret_key_base!

    result = run

    expect(result.resigned).to eq(0)
    expect(result.unmatched).to contain_exactly(hash_including(reason: :no_reference, target_type: 'Note', target_id: target.id))
  end

  it 'refuses an image that is not attached to this text' do
    foreign = png_blob('fremd.png')
    ticket = ticket_with_body("<div>x</div>#{node(foreign)}")
    rotate_secret_key_base!

    result = run

    expect(result.resigned).to eq(0)
    expect(result.unmatched).to contain_exactly(
      hash_including(rich_text_id: ticket.content.id, reason: :not_attached, target_type: 'ActiveStorage::Blob', target_id: foreign.id)
    )
    expect(resolves?(sgids_of(ticket).first)).to be(false)
  end

  it 'gives a forged, unsigned node nothing it could not already show' do
    foreign = png_blob('fremd.png')
    ticket = ticket_with_body(%(<div>x</div><action-text-attachment sgid="#{unsigned_sgid(foreign)}"></action-text-attachment>))

    expect(run.resigned).to eq(0)
    expect(resolves?(sgids_of(ticket).first)).to be(false)
  end

  it 'matches a Marshal node to its embed by filename and filesize, without loading the payload' do
    blob = png_blob('alt.png')
    ticket = ticket_with_body(%(<div>x</div><action-text-attachment sgid="#{marshal_sgid(blob)}" filename="alt.png" filesize="#{blob.byte_size}"></action-text-attachment>))
    attach_embed(ticket.content, blob)
    expect(Marshal).not_to receive(:load)

    expect(run.resigned).to eq(1)
    expect(ActionText::Attachable.from_attachable_sgid(sgids_of(ticket).first)).to eq(blob)
  end

  it 'lists a Marshal node it cannot match' do
    blob = png_blob('alt.png')
    ticket = ticket_with_body(%(<div>x</div><action-text-attachment sgid="#{marshal_sgid(blob)}" filename="anders.png" filesize="1"></action-text-attachment>))
    attach_embed(ticket.content, blob)

    result = run

    expect(result.resigned).to eq(0)
    expect(result.unmatched).to contain_exactly(hash_including(reason: :unreadable, filename: 'anders.png', target_id: nil))
  end

  it 'lists an image whose blob is gone so it can be restored from the backup' do
    blob = png_blob
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(blob)}")
    ticket.content.embeds.each(&:destroy!)
    blob.purge
    rotate_secret_key_base!

    result = run

    expect(result.resigned).to eq(0)
    expect(result.unmatched).to contain_exactly(
      hash_including(rich_text_id: ticket.content.id, reason: :not_attached, target_type: 'ActiveStorage::Blob', target_id: blob.id)
    )
  end
end

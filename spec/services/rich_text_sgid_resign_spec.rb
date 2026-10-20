# frozen_string_literal: true

require 'rails_helper'

# What:  RichTextSgidResign re-signs the attachment nodes of stored rich texts whose sgid
#        was signed with the previous secret_key_base.
# Type:  Service spec (2026-10-20).
# Why:   A secret_key_base rotation turns every stored image and wiki mention into a
#        "☒". The old key comes only from the one run of the task, so a node is accepted
#        only when the old key signed it AND its target belongs to this text: an image
#        only when it is attached to THIS text, a mention only within the text's own
#        organisation. Others may hold a rotated key; a sgid forged with it must gain nothing.
RSpec.describe RichTextSgidResign, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:old_secret_key_base) { Rails.application.secret_key_base }

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

  # What a rotation does: the sgids written so far were signed with the key
  # the application booted with, every one minted from now on uses the new key.
  def rotate_secret_key_base!
    key = ActiveSupport::KeyGenerator.new('a-rotated-secret-key-base' * 4, iterations: 1000)
                                     .generate_key('signed_global_ids')
    SignedGlobalID.verifier = GlobalID::Verifier.new(key)
  end

  def sgids_of(record)
    Nokogiri::HTML.fragment(record.reload.content.body.to_html).css('action-text-attachment').map { |n| n['sgid'] }
  end

  def resolves?(sgid)
    ActionText::Attachable.from_attachable_sgid(sgid).present?
  rescue ActiveRecord::RecordNotFound
    false
  end

  def run(dry_run: false) = described_class.call(old_secret_key_base: old_secret_key_base, dry_run: dry_run)

  it 'brings back an image of the text and renders it instead of the glyph' do
    blob = png_blob
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>Schritt 1</div>#{node(blob)}")
    rotate_secret_key_base!
    expect(Ticket.find(ticket.id).content.to_s).to include('☒')

    result = run

    expect(result.resigned).to eq(1)
    expect(sgids_of(ticket)).to all(satisfy { |sgid| resolves?(sgid) })
    expect(Ticket.find(ticket.id).content.to_s).not_to include('☒')
  end

  it 'reports without writing in dry run' do
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(png_blob)}")
    stale = sgids_of(ticket)
    rotate_secret_key_base!

    result = run(dry_run: true)

    expect(result.to_h).to include(changed: 1, resigned: 1, dry_run: true)
    expect(sgids_of(ticket)).to eq(stale)
  end

  it 'leaves nodes that already resolve alone and is idempotent' do
    create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(png_blob)}")
    rotate_secret_key_base!
    run

    expect(run.to_h).to include(changed: 0, resigned: 0)
  end

  it 'brings back a wiki mention within the organisation and re-derives the markdown body' do
    target = create(:note, project: project, organisation: organisation, title: 'Zielnotiz')
    note = create(:note, project: project, organisation: organisation, content: "<div>Siehe</div>#{mention(target)}")
    rotate_secret_key_base!
    note.update_column(:markdown_body, 'stale')

    expect(run.resigned).to eq(1)
    expect(resolves?(sgids_of(note).first)).to be(true)
    expect(note.reload.markdown_body).to eq(Wiki::MarkdownSerializer.new.to_markdown(note.content.body.to_html))
  end

  it 'refuses an image that is not attached to this text' do
    foreign = png_blob('fremd.png')
    ticket = create(:ticket, project: project, organisation: organisation, content: '<div>x</div>')
    ticket.content.update_column(:body, "<div>x</div>#{node(foreign)}")
    rotate_secret_key_base!

    result = run

    expect(result.resigned).to eq(0)
    expect(result.refused).to contain_exactly(hash_including(rich_text_id: ticket.content.id, target_type: 'ActiveStorage::Blob', target_id: foreign.id))
    expect(resolves?(sgids_of(ticket).first)).to be(false)
  end

  it 'refuses a mention of a record in another organisation' do
    other = create(:organisation)
    target = ActsAsTenant.with_tenant(other) do
      create(:note, project: create(:project, organisation: other), organisation: other, title: 'Fremd')
    end
    note = create(:note, project: project, organisation: organisation, content: '<div>x</div>')
    note.content.update_column(:body, "<div>x</div>#{mention(target)}")
    rotate_secret_key_base!

    result = run

    expect(result.resigned).to eq(0)
    expect(result.refused).to contain_exactly(hash_including(target_type: 'Note', target_id: target.id))
  end

  it 'refuses a sgid the old key did not sign, without decoding it' do
    blob = png_blob
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(blob)}")
    rotate_secret_key_base!

    result = described_class.call(old_secret_key_base: 'not-the-old-key' * 8, dry_run: false)

    expect(result.to_h).to include(resigned: 0, unreadable: 1)
    expect(resolves?(sgids_of(ticket).first)).to be(false)
  end

  it 'lists an image whose blob is gone so it can be restored from the backup' do
    blob = png_blob
    ticket = create(:ticket, project: project, organisation: organisation, content: "<div>x</div>#{node(blob)}")
    ticket.content.embeds.each(&:destroy!)
    blob.purge
    rotate_secret_key_base!

    result = run

    expect(result.resigned).to eq(0)
    expect(result.gone).to contain_exactly(hash_including(rich_text_id: ticket.content.id, target_type: 'ActiveStorage::Blob', target_id: blob.id))
  end

  it 'refuses to run without the old key' do
    expect { described_class.call(old_secret_key_base: '', dry_run: true) }.to raise_error(ArgumentError)
  end
end

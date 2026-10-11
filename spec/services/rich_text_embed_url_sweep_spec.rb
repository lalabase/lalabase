# frozen_string_literal: true

require 'rails_helper'

# What:  RichTextEmbedUrlSweep removes url/href from stored attachment nodes, once, for the
#        rich texts written before RichTextEmbedGuard existed (spike plan D9).
# Type:  Service spec (2026-08-23).
# Why:   The stored url held a signed_id without expiry. The sweep must touch only that
#        attribute (no validation, no NoteVersion, no embeds churn), be idempotent, honour
#        the dry run, and keep a note's derived markdown_body in step.
RSpec.describe RichTextEmbedUrlSweep do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 64}"), filename: 'shot.png', content_type: 'image/png')
  end
  let(:legacy_html) do
    %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}" url="https://x/rails/active_storage/blobs/redirect/abc/shot.png" href="https://x/y" filename="shot.png"></action-text-attachment>)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Written the way the production rows were: straight into the column, no guard.
  def legacy_note
    create(:note, project: project, organisation: organisation, content: '<div>x</div>').tap do |note|
      note.content.update_column(:body, legacy_html)
      note.update_column(:markdown_body, Wiki::MarkdownSerializer.new.to_markdown(legacy_html))
    end.reload
  end

  it 'reports without writing in dry run' do
    note = legacy_note

    result = described_class.call(dry_run: true)

    expect(result.to_h).to include(scanned: 1, changed: 1, dry_run: true)
    expect(note.reload.content.body.to_html).to include('url=')
  end

  it 'removes url and href, keeps everything else, and re-derives the markdown body' do
    note = legacy_note
    versions_before = NoteVersion.count

    result = described_class.call(dry_run: false)
    node = Nokogiri::HTML.fragment(note.reload.content.body.to_html).at_css('action-text-attachment')

    expect(result.changed).to eq(1)
    expect(node['url']).to be_nil
    expect(node['href']).to be_nil
    expect(node['sgid']).to be_present
    expect(node['filename']).to eq('shot.png')
    expect(note.markdown_body).not_to include('url=')
    expect(NoteVersion.count).to eq(versions_before)
  end

  it 'is idempotent: a second run changes nothing' do
    legacy_note
    described_class.call(dry_run: false)

    expect(described_class.call(dry_run: false).changed).to eq(0)
  end

  it 'leaves texts without attachment nodes alone' do
    create(:note, project: project, organisation: organisation, content: '<div>nur Text</div>')

    expect(described_class.call(dry_run: false).to_h).to include(scanned: 0, changed: 0)
  end
end

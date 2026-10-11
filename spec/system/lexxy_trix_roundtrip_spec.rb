# frozen_string_literal: true

require 'rails_helper'

# What:  Lexxy loads the three attachment shapes Trix left in production texts (single
#        image, two-image gallery, PDF tile), and saving the text UNCHANGED writes the
#        attachment nodes back intact.
# Type:  System spec with headless Chrome (spike S9 / decision D12, 2026-08-23). Runs by
#        hand: spec/system is not in the CI list.
# Why:   Paket 2 makes Lexxy the editor of ticket descriptions and comments, where 79
#        embeds from the Trix era live today (S7). If Lexxy rewrote or dropped those nodes
#        on the first edit, 79 images would be damaged without anyone touching them. This
#        spec is the gate for Paket 2: green means the switch needs no migration of stored
#        HTML. `url`/`href` are expected to disappear (RichTextEmbedGuard, D9); everything
#        else (sgid, content-type, filename, filesize, width, height, presentation, the
#        gallery wrapper) must survive.
RSpec.describe 'Lexxy round trip of Trix-era attachments', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }

  def image_blob(name)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: name, content_type: 'image/png')
  end

  def pdf_blob
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF-1.4 x'), filename: 'ablauf.pdf', content_type: 'application/pdf')
  end

  # The node exactly as Trix wrote it in 2025: sgid plus the descriptive attributes and the
  # then-permanent url.
  def trix_node(blob, presentation: nil, width: 1, height: 1)
    attrs = {
      'sgid' => blob.attachable_sgid, 'content-type' => blob.content_type, 'filename' => blob.filename.to_s,
      'filesize' => blob.byte_size, 'url' => "https://lalabase.test/rails/active_storage/blobs/redirect/#{blob.signed_id}/#{blob.filename}"
    }
    attrs['width'] = width and attrs['height'] = height if blob.content_type.start_with?('image/')
    attrs['presentation'] = presentation if presentation
    %(<action-text-attachment #{attrs.map { |k, v| %(#{k}="#{v}") }.join(' ')}></action-text-attachment>)
  end

  let(:single) { image_blob('einzel.png') }
  let(:gallery_a) { image_blob('galerie-a.png') }
  let(:gallery_b) { image_blob('galerie-b.png') }
  let(:pdf) { pdf_blob }

  let(:trix_html) do
    <<~HTML.gsub(/\n\s*/, '')
      <div>Schritt 1</div>
      #{trix_node(single)}
      <div>Schritt 2</div>
      <div class="attachment-gallery attachment-gallery--2">#{trix_node(gallery_a, presentation: 'gallery')}#{trix_node(gallery_b, presentation: 'gallery')}</div>
      <div>Schritt 3</div>
      #{trix_node(pdf)}
      <div>Ende</div>
    HTML
  end

  # `stored_html` is what the column holds: the Trix-era HTML either as written in 2025
  # (with url) or after RichTextEmbedUrlSweep (without url). Saved WITHOUT validation, the
  # way the production rows came to be (before the guard existed), so ActionText attaches
  # the embeds like it did back then; the delta validator then treats them as existing.
  let(:stored_html) { trix_html }
  let!(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation, creator: user, title: 'Trix-Bestand', content: '<div>x</div>').tap do |n|
        n.content.body = stored_html
        n.save!(validate: false)
        # Since Rails 8.1 the rich text collects its embeds in before_validation, which
        # validate: false skips. The production rows have theirs, so attach them here.
        n.content.embeds.attach(n.content.body.attachables.grep(ActiveStorage::Blob))
        n.content.update_column(:body, stored_html) # the guard is not in the way here, but url must be exactly as stored
      end
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    login_as(user, scope: :user)
  end

  def attachment_nodes(html)
    Nokogiri::HTML.fragment(html).css('action-text-attachment').map do |node|
      node.attributes.transform_values(&:value).except('url', 'href', 'content')
    end
  end

  def open_editor
    visit organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')
    # The hook class sits on the pencil link itself (knowledge/_lane_head).
    find('a.note-edit-button', visible: :all).click
    find('lexxy-editor', wait: 10)
    find('.lexxy-editor__content', wait: 10)
    sleep 1 # give Lexical its import pass
    @editor_content = page.evaluate_script("document.querySelector('.lexxy-editor__content').innerHTML")
  end

  def save
    click_button I18n.t('views.organisations.notes.note_edit.save')
    expect(page).to have_content('Trix-Bestand', wait: 10)
    sleep 1
  end

  # Types at the very end of the text, so the body really changes and the save writes.
  def append_text(text)
    page.execute_script(<<~JS)
      const content = document.querySelector('.lexxy-editor__content');
      content.focus();
      const selection = window.getSelection();
      selection.selectAllChildren(content);
      selection.collapseToEnd();
    JS
    find('.lexxy-editor__content').send_keys(text)
  end

  def open_editor_and_save_unchanged
    open_editor
    save
  end

  # The contract Paket 2 relies on: the REFERENCES survive (every sgid, in order, still
  # attached), the text survives, and nothing permanent or redundant is left behind.
  # Lexxy normalises the rest on every save, measured 23.08.2026 (Lexxy 0.9.18):
  #   * <div> paragraphs become <p>;
  #   * nodes that still carry url keep their attributes and ALL get presentation="gallery";
  #   * nodes without url (after the sweep) come back as sgid + `content` (the rendered
  #     partial); the guard drops that `content` again, the descriptive attributes
  #     (filename, filesize, width, height) are gone, ActionText re-derives them from the blob.
  def expect_references_intact(expected_text_count: 3)
    before_nodes = attachment_nodes(trix_html)
    after_html = note.content.reload.body.to_html
    after_nodes = attachment_nodes(after_html)

    aggregate_failures do
      expect(after_nodes.map { |n| n['sgid'] }).to eq(before_nodes.map { |n| n['sgid'] })
      expect(after_html).not_to include('blobs/redirect')
      expect(after_html).not_to include('content=')
      expect(after_html.scan('Schritt').size).to eq(expected_text_count)
      expect(note.content.embeds.count).to eq(4)
      expect(note.content.to_s).to include('<img').and include('ablauf.pdf')
    end
  end

  # Control: a node exactly as Lexxy itself writes it (production note, 2026-08), to tell a
  # Trix-shape problem from a test-environment problem.
  context 'control: a node in the shape Lexxy writes itself' do
    let(:stored_html) do
      %(<p>Schritt 1</p><action-text-attachment sgid="#{single.attachable_sgid}" url="https://lalabase.test/rails/active_storage/blobs/redirect/#{single.signed_id}/einzel.png" alt="einzel.png" caption="" content-type="image/png" filename="einzel.png" filesize="#{single.byte_size}" presentation="gallery"></action-text-attachment><p><br></p>)
    end

    it 'shows the attachment in the editor and keeps it through an edit' do
      open_editor
      expect(@editor_content).to include('einzel.png')

      append_text(' Nachtrag')
      save
      expect(note.reload.content.body.to_html).to include('einzel.png').and include('Nachtrag')
      expect(note.content.embeds.count).to eq(1)
    end
  end

  context 'with the nodes as Trix wrote them (url present, like the 88 production rows today)' do
    it 'shows the four attachments; an unchanged save already normalises the markup but keeps every reference' do
      open_editor
      expect(@editor_content).to include('einzel.png').and include('ablauf.pdf')

      save
      expect_references_intact
    end

    it 'keeps every reference through a text edit' do
      open_editor
      append_text(' Nachtrag')
      save

      expect_references_intact
      expect(note.content.reload.body.to_html).to include('Nachtrag')
    end
  end

  context 'with the nodes after RichTextEmbedUrlSweep (url stripped)' do
    let(:stored_html) { Nokogiri::HTML.fragment(trix_html).tap { |f| f.css('action-text-attachment').each { |n| n.remove_attribute('url') } }.to_html }

    it 'shows the four attachments and keeps every reference through a text edit' do
      open_editor
      expect(@editor_content).to include('einzel.png').and include('ablauf.pdf')

      append_text(' Nachtrag')
      save

      expect_references_intact
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What:  The Lexxy editor shows an embedded image whose stored attachment node carries NO
#        `url` attribute, and the editor advertises the image rule of RichTextEmbeds.
# Type:  Request spec, the "editor probe" of decision D9 (spike plan Inline-Bilder).
# Why:   RichTextEmbedGuard strips `url`/`href` on save because the stored url held a
#        signed_id without expiry. Lexxy's tag helper renders a node without url through
#        the attachment partial into the node's `content` (lexxy/rich_text_area_tag.rb,
#        render_custom_attachments_in), so the editor must still show the picture, now with
#        a fresh, expiring link. If Lexxy ever drops that path, this spec goes red before a
#        user sees an empty tile.
RSpec.describe 'Note editor with an embedded image', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: admin_role, active: true)
    end
    u
  end
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }
  let(:blob) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'shot.png', content_type: 'image/png') }
  let!(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation, creator: member,
                    content: %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}" url="https://x/rails/active_storage/blobs/redirect/abc/shot.png"></action-text-attachment>))
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in member
  end
  after { ActsAsTenant.current_tenant = nil }

  it 'stored the node without url (the guard stripped it)' do
    node = Nokogiri::HTML.fragment(note.content.body.to_html).at_css('action-text-attachment')
    expect(node['url']).to be_nil
  end

  it 'renders the image into the editor from the attachment partial, with a fresh link' do
    get edit_organisation_project_note_path(organisation, project, note), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:ok)

    editor = Nokogiri::HTML.fragment(response.body).at_css('lexxy-editor')
    expect(editor).to be_present
    node = Nokogiri::HTML.fragment(editor['value'].to_s).at_css('action-text-attachment')
    expect(node).to be_present
    content = JSON.parse(node['content'].to_s)
    expect(content).to include('<img')
    expect(content).to include('/rails/active_storage/representations/')
    expect(content).not_to include('/blobs/redirect/abc/')
  end

  it 'advertises the image rule to the editor and the browser handler' do
    get edit_organisation_project_note_path(organisation, project, note), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    editor = Nokogiri::HTML.fragment(response.body).at_css('lexxy-editor')

    # Lexxy's own attribute must stay absent: it also filters STORED content on load.
    expect(editor['permitted-attachment-types']).to be_nil
    expect(editor['data-neo-rich-text-embeds-image-types-value']).to eq(RichTextEmbeds.permitted_attachment_types)
    expect(editor['data-neo-rich-text-embeds-max-bytes-value']).to eq(RichTextEmbeds::MAX_BYTE_SIZE.to_s)
    expect(editor['data-controller']).to include('neo-rich-text-embeds')
    expect(editor['data-neo-rich-text-embeds-max-megabytes-value']).to eq(RichTextEmbeds.max_megabytes.to_s)
    expect(editor['data-hint-too-large']).to include('%{max}'.dup) # rubocop:disable Style/FormatStringToken -- interpolated by the controller
    expect(editor['data-neo-rich-text-embeds-attachment-selector-value']).to be_nil # notes have no attachment field
    # …so a refused file goes nowhere: no "moved to the attachments field", but the one
    # remedy that works without an attachment field.
    expect(editor['data-hint-redirected']).to be_nil
    expect(editor['data-hint-shrink']).to eq(I18n.t('views.action_text.embed_hint_shrink'))
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What:  Every ticket and comment form renders Lexxy with the image rule, and rendered
#        rich texts carry the zoom wrapper and the zoom link around inline images.
# Type:  Request spec (doc/inline_bilder_paket_2_plan.md, P2-1 and P2-3, 2026-08-23).
# Why:   Paket 2 moved six Trix forms to lexxy_rich_text_area through
#        RichTextEmbedsHelper#lexxy_embed_editor_options. The static no-Trix guard proves
#        the call sites; this spec proves the rendered result on the real routes: the
#        editor element, the attachment field the courtesy check redirects to, and the
#        content wrapper the lightbox is delegated on. A form rendering `trix-editor` here
#        would ship images without rule and without zoom.
RSpec.describe 'Rich text editor forms (Lexxy) and rendered images', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }
  let(:blob) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'shot.png', content_type: 'image/png') }
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, creator: user,
                    content: %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment>))
  end
  let(:post_record) do
    ActsAsTenant.current_tenant = organisation
    create(:post, ticket: ticket, user: user, organisation: organisation, content: '<div>Kommentar</div>')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end
  after { ActsAsTenant.current_tenant = nil }

  def editors
    Nokogiri::HTML.fragment(response.body).css('lexxy-editor')
  end

  def expect_lexxy_with_rule(editor, attachment_field:)
    expect(editor).to be_present
    expect(editor['data-controller']).to include('neo-rich-text-embeds')
    expect(editor['data-neo-rich-text-embeds-image-types-value']).to eq(RichTextEmbeds.permitted_attachment_types)
    expect(editor['data-neo-rich-text-embeds-max-bytes-value']).to eq(RichTextEmbeds::MAX_BYTE_SIZE.to_s)
    expect(editor['permitted-attachment-types']).to be_nil
    expect(editor['data-neo-rich-text-embeds-attachment-selector-value']).to eq(%(input[type="file"][name="#{attachment_field}"]))
    # A form WITH an attachment field says where the file went; it must not also ask the
    # user to shrink and re-insert, that hint belongs to forms without a redirect target.
    expect(editor['data-hint-redirected']).to eq(I18n.t('views.action_text.embed_hint_redirected'))
    expect(editor['data-hint-shrink']).to be_nil
    expect(response.body).not_to include('<trix-editor')
  end

  # Since Paket 3 the ticket list no longer embeds a creation form; tickets#new and
  # tickets#edit render the one writing surface into turbo-frame#writing_surface on demand.
  it 'renders the ticket writing surface (new) with Lexxy and the ticket attachment field as redirect target' do
    get new_organisation_project_ticket_path(organisation, project), headers: { 'Turbo-Frame' => 'writing_surface' }
    expect(response).to have_http_status(:ok)

    form_editor = editors.find { |e| e['name'] == 'ticket[content]' }
    expect_lexxy_with_rule(form_editor, attachment_field: 'ticket[ticket_document_files][]')
    expect(response.body).to include('name="ticket[ticket_document_files][]"')
  end

  it 'renders the ticket writing surface (edit) with Lexxy' do
    get edit_organisation_project_ticket_path(organisation, project, ticket), headers: { 'Turbo-Frame' => 'writing_surface' }
    expect(response).to have_http_status(:ok)

    expect_lexxy_with_rule(editors.first, attachment_field: 'ticket[ticket_document_files][]')
  end

  it 'renders the comment form on the ticket page with Lexxy and the post attachment field' do
    get organisation_project_ticket_path(organisation, project, ticket)
    expect(response).to have_http_status(:ok)

    comment_editor = editors.find { |e| e['name'] == 'post[content]' }
    expect_lexxy_with_rule(comment_editor, attachment_field: 'post[post_document_files][]')
  end

  it 'renders the comment edit form with Lexxy' do
    get edit_organisation_project_ticket_post_path(organisation, project, ticket, post_record)
    expect(response).to have_http_status(:ok)

    expect_lexxy_with_rule(editors.first, attachment_field: 'post[post_document_files][]')
  end

  it 'renders the ticket description inside the zoom wrapper with a zoom link around the image' do
    get organisation_project_ticket_path(organisation, project, ticket)
    doc = Nokogiri::HTML.fragment(response.body)

    wrapper = doc.css('div.lexxy-content[data-controller="neo-rich-text-zoom"]').find { |w| w.to_html.include?('Schritt 1') }
    expect(wrapper).to be_present
    zoom = wrapper.at_css('a.attachment__zoom')
    expect(zoom).to be_present
    expect(zoom['href']).to include('/rails/active_storage/representations/')
    expect(zoom.at_css('img')).to be_present
    expect(zoom.at_css('img')['src']).to include('/rails/active_storage/representations/')
    expect(zoom['href']).not_to eq(zoom.at_css('img')['src']) # zoom variant differs from the display variant
    # The title names the action, the alt names the picture: the filename must not be the
    # accessible name twice (the figcaption already prints it a third time).
    expect(zoom['title']).to eq(I18n.t('views.action_text.zoom_open'))
    expect(zoom.at_css('img')['alt']).to eq('shot.png')
  end
end

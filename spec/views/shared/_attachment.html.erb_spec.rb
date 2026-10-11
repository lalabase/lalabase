# frozen_string_literal: true

require 'rails_helper'

# Integration regression for the attachment preview (the layer the #138 disposition fix
# could NOT reach). A previewable attachment (PDF/image) renders as a thumbnail in
# shared/_attachment. That thumbnail MUST be wrapped in a link that opens the file via
# the authorized proxy in a new tab — otherwise the <img> has no click target and
# clicking a PDF preview does nothing. This renders the REAL partial, not the controller
# in isolation, which is exactly the gap that let the original bug ship.
RSpec.describe 'shared/_attachment', type: :view do
  let(:organisation) { create(:organisation) }

  # PNG => image?/variable? true (no PDF previewer binary needed => deterministic in CI).
  # The open-link wraps all three preview sub-branches identically, so the PNG case proves
  # the wrapping for the PDF (previewable?) path too.
  let(:ticket_document) do
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      ticket  = create(:ticket, project: project, organisation: organisation)
      create(:ticket_document, :with_png, ticket: ticket, organisation: organisation)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def render_attachment
    render partial: 'shared/attachment',
           locals: { document: ticket_document, file_accessor: :ticket_document_file }
    Nokogiri::HTML.fragment(rendered)
  end

  it 'wraps the preview thumbnail in a link that opens the file inline in a new tab' do
    doc = render_attachment
    expected_href = view.attachment_download_path(ticket_document)

    open_link = doc.at_css("a[href='#{expected_href}'][target='_blank']")

    expect(open_link).not_to be_nil, 'preview is not wrapped in an open-in-new-tab link'
    expect(open_link.at_css('img')).not_to be_nil, 'open link does not wrap the preview image'
    expect(open_link['rel'].to_s).to include('noopener')
  end

  it 'points the open-link at the authorized proxy (so the inline disposition applies)' do
    doc = render_attachment
    open_link = doc.at_css("a[target='_blank']")

    expect(open_link).not_to be_nil, 'no open-in-new-tab link rendered'
    # The proxy path, not the unprotected default ActiveStorage blob route.
    expect(open_link['href']).to eq(view.attachment_download_path(ticket_document))
    expect(open_link['href']).not_to include('/rails/active_storage/')
  end

  it 'offers the zoom lightbox for a real raster image' do
    doc = render_attachment
    # The lightbox renders an <img>; it is gated to file.image? so PDFs never get it.
    expect(doc.at_css('button[data-action*="image-lightbox#openLightbox"]')).not_to be_nil
  end

  # Post attachments were rendered by a divergent twin partial
  # (organisations/posts/_attachment) that PR #140 never touched, so the fix above did
  # NOT reach them. They are now unified onto this shared partial. These examples render
  # this partial with a PostDocument to guard the unified path and the dispatch helper.
  context 'for a PostDocument (the unified posts render path)' do
    let(:post_document) do
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        ticket  = create(:ticket, project: project, organisation: organisation)
        post    = create(:post, ticket: ticket, organisation: organisation)
        # Default factory attaches a .txt => not image/previewable => the else (file) branch,
        # which is exactly the plain-text "PDF won't open" case the user reported in dev
        # (no pdftoppm => a PDF also lands here).
        create(:post_document, post: post, organisation: organisation)
      end
    end

    def render_post_attachment
      render partial: 'shared/attachment',
             locals: { document: post_document, file_accessor: :post_document_file }
      Nokogiri::HTML.fragment(rendered)
    end

    it 'links a non-previewable file at the post proxy AND opens it in a new tab' do
      frag = render_post_attachment
      expected_href = view.post_document_download_path(post_document)

      link = frag.at_css("a[href='#{expected_href}']")
      expect(link).not_to be_nil, 'filename is not a link to the authorized post-document proxy'
      # Without target=_blank, Turbo Drive intercepts the click, fetches a non-HTML body and
      # silently does nothing — the exact "clicking the PDF does nothing" bug.
      expect(link['target']).to eq('_blank'), 'file link lacks target=_blank => Turbo swallows the click'
      expect(link['rel'].to_s).to include('noopener')
    end

    it 'gives the file link a recognizable affordance (type icon + always-on underline)' do
      frag = render_post_attachment
      link = frag.at_css('a[target="_blank"]')

      expect(link).not_to be_nil
      expect(link.at_css('i.bi')).not_to be_nil, 'no file-type icon to signal this is a file link'
      expect(link['class'].to_s).to include('underline'), 'link is not underlined => looks like plain text'
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# R6 regression guard: post-document and ticket-document attachments must be served through
# the authorized proxy (TicketPolicy#show? → project :tickets access), not the unauthenticated
# default blob route. A member without project access gets a uniform 404 (no existence leak).
RSpec.describe 'Organisations::FileDownloads post/ticket documents', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  let(:ticket_a) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project_a, organisation: organisation) } }
  let(:post_a) { ActsAsTenant.with_tenant(organisation) { create(:post, ticket: ticket_a, organisation: organisation) } }
  let(:post_document) do
    ActsAsTenant.with_tenant(organisation) { create(:post_document, post: post_a, organisation: organisation) }
  end
  let(:ticket_document) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket_document, ticket: ticket_a, organisation: organisation) }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def download(kind:, id:)
    get organisation_file_download_path(organisation_id: organisation.id, kind: kind, id: id)
  end

  describe 'post_document' do
    it 'serves the bytes to a member with tickets access' do
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
      sign_in member

      download(kind: 'post_document', id: post_document.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('test file content')
    end

    it 'returns 404 (no existence leak) for a member without project access' do
      sign_in member

      download(kind: 'post_document', id: post_document.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'ticket_document' do
    it 'serves the bytes to a member with tickets access' do
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
      sign_in member

      download(kind: 'ticket_document', id: ticket_document.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('test file content')
    end

    it 'returns 404 (no existence leak) for a member without project access' do
      sign_in member

      download(kind: 'ticket_document', id: ticket_document.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  # Authorization is bound to a SPECIFIC area + project via the kind's authorize_target.
  # These tests pin that binding: the proxy must use the *tickets* area (not documents) and
  # the *owning* project — the leak class this controller was built to close.
  describe 'authorization area + project binding' do
    it 'returns 404 for a ticket_document when the member has documents_access but NOT tickets_access' do
      # Wrong area on purpose: if authorize_target ever resolved through DocumentPolicy
      # (documents_access), this would wrongly return 200.
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only', tickets_access: 'no_access')
      sign_in member

      download(kind: 'ticket_document', id: ticket_document.id)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_blank # uniform 404, no existence/content leak
    end

    it 'returns 404 for a post_document when the member has documents_access but NOT tickets_access' do
      create(:project_permission, user: member, project: project_a, documents_access: 'read_only', tickets_access: 'no_access')
      sign_in member

      download(kind: 'post_document', id: post_document.id)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a ticket_document in another project of the SAME org (cross-project, no tenant help)' do
      # tickets_access is granted, but on the WRONG project. Tenant scoping does not help here
      # (same org) — only the per-project Pundit check stands between the user and the file.
      project_b = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ticket_b = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project_b, organisation: organisation) }
      foreign_doc = ActsAsTenant.with_tenant(organisation) do
        create(:ticket_document, ticket: ticket_b, organisation: organisation)
      end
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
      sign_in member

      download(kind: 'ticket_document', id: foreign_doc.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'missing attachment (attached? guard on the ticket path)' do
    it 'returns 404 when the ticket_document record exists but its blob was purged' do
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
      ticket_document.ticket_document_file.purge
      sign_in member

      download(kind: 'ticket_document', id: ticket_document.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  # Disposition regression (preview vs forced download): clicking an attachment used to
  # always download because the proxy hardcoded `disposition: 'attachment'`. We now request
  # `inline`, but lean on Rails' allowlist (ActiveStorage.content_types_allowed_inline) so
  # only safe, previewable types open inline — script-capable uploads stay downloads.
  # The four cases together prove the decision is the content-type allowlist, NOT "is it an
  # image" (PNG inline but SVG download) and NOT a blanket inline (HTML download).
  describe 'Content-Disposition' do
    let(:pdf_document)  { ActsAsTenant.with_tenant(organisation) { create(:ticket_document, :with_pdf,  ticket: ticket_a, organisation: organisation) } }
    let(:png_document)  { ActsAsTenant.with_tenant(organisation) { create(:ticket_document, :with_png,  ticket: ticket_a, organisation: organisation) } }
    let(:html_document) { ActsAsTenant.with_tenant(organisation) { create(:ticket_document, :with_html, ticket: ticket_a, organisation: organisation) } }
    let(:svg_document)  { ActsAsTenant.with_tenant(organisation) { create(:ticket_document, :with_svg,  ticket: ticket_a, organisation: organisation) } }

    before do
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
      sign_in member
    end

    it 'serves a PDF inline so it opens in the browser instead of downloading' do
      download(kind: 'ticket_document', id: pdf_document.id)

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to match(/\Ainline\b/)
    end

    it 'serves a PNG image inline (allowlist covers more than just PDF)' do
      download(kind: 'ticket_document', id: png_document.id)

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to match(/\Ainline\b/)
      expect(response.media_type).to eq('image/png')
    end

    it 'still forces download for script-capable types (HTML) — no inline XSS from our origin' do
      download(kind: 'ticket_document', id: html_document.id)

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to match(/\Aattachment\b/)
    end

    it 'forces download for SVG even though it is an image (SVG can embed <script>)' do
      download(kind: 'ticket_document', id: svg_document.id)

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Disposition']).to match(/\Aattachment\b/)
      # Rails additionally neuters it by serving as binary, not image/svg+xml.
      expect(response.media_type).to eq('application/octet-stream')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What: DocumentVersion#broadcast_updated, the update that reaches an open
#   document (after_update_commit).
# Type: model spec on real records; the broadcasts are stubbed, the partial is
#   rendered the way the broadcast renders it, without a request.
# Why: the head's AI status reads the current version's flag (S3 of
#   doc/dokumentansicht_plan.md), and the row's broadcast used to replace the
#   row alone: a retry that succeeded while the document was open cleared the
#   row's failure and left the head's standing (review of #783). Both go out
#   together, and the status partial must render without a viewer.
RSpec.describe DocumentVersion do
  let(:organisation) { create(:organisation, ai_enabled: false) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:document) { create(:document, project: project, organisation: organisation, creator: user) }
  let(:version) do
    v = create(:document_version, document: document, organisation: organisation, number: 1, embeddings_creation_flag: false)
    document.update!(current_version: v)
    v
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'replaces the row AND the head status when a version changes' do
    version
    allow(version).to receive(:broadcast_replace_to)

    version.update!(embeddings_creation_flag: true)

    stream = "#{ActionView::RecordIdentifier.dom_id(document)}_document_versions"
    expect(version).to have_received(:broadcast_replace_to)
      .with(stream, hash_including(partial: 'organisations/documents/version_row',
                                   target: "#{ActionView::RecordIdentifier.dom_id(version)}_document_versions"))
    expect(version).to have_received(:broadcast_replace_to)
      .with(stream, hash_including(partial: 'organisations/documents/ai_state',
                                   target: "#{ActionView::RecordIdentifier.dom_id(document)}_ai_state"))
  end

  it 'renders the head status the way the broadcast does, without a viewer, and with the flag as it is now' do
    version.update!(embeddings_creation_flag: true)

    html = ApplicationController.render(partial: 'organisations/documents/ai_state',
                                        locals: { document: document.reload, organisation: organisation })

    expect(html).to include("id=\"#{ActionView::RecordIdentifier.dom_id(document)}_ai_state\"")
    expect(html).to include('data-document-ai-state="indexed"')
    expect(html).not_to include('fehlgeschlagen')
  end
end

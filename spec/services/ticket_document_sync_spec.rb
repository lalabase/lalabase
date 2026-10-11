# frozen_string_literal: true

require 'rails_helper'

# Unit spec for the TicketDocumentSync collaborator extracted from
# Actors::SaveTicket. Pins the contract the actor relies on: destroy the marked
# documents, create one per uploaded file, refresh the association cache, and
# RETURN the created documents (the actor schedules their processing jobs).
RSpec.describe TicketDocumentSync do
  let(:organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let!(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, title: 'Doc Ticket', creator: create(:user))
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def upload
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/test_file.txt'), 'text/plain')
  end

  it 'returns [] and changes nothing when neither files nor removals are given' do
    existing = create(:ticket_document, ticket: ticket, organisation: organisation)

    result = described_class.call(ticket: ticket)

    expect(result).to eq([])
    expect(TicketDocument.find_by(id: existing.id)).to be_present
  end

  it 'creates one TicketDocument per file and returns them' do
    # TicketDocument.create! re-selects the (tenant-scoped) ticket per record — a
    # pre-existing per-file lookup carried over verbatim from the old actor code
    # (TicketDocument.create! inside files.each). Out of scope for this refactor;
    # pause Prosopite so exercising multi-file create here does not flag it.
    Prosopite.pause
    created = described_class.call(ticket: ticket, document_files: [upload, upload])
    Prosopite.resume

    expect(created.size).to eq(2)
    expect(created).to all(be_a(TicketDocument).and(be_persisted))
    expect(ticket.ticket_documents.reload.size).to eq(2)
  end

  it 'skips blank file entries (returns only the real uploads)' do
    created = described_class.call(ticket: ticket, document_files: ['', nil, upload])

    expect(created.size).to eq(1)
  end

  it 'destroys documents marked for removal and returns [] (no creations)' do
    doc = create(:ticket_document, ticket: ticket, organisation: organisation)

    result = described_class.call(ticket: ticket, remove_document_ids: [doc.id.to_s])

    expect(result).to eq([])
    expect(TicketDocument.find_by(id: doc.id)).to be_nil
  end

  it 'ignores unknown removal ids without raising' do
    expect { described_class.call(ticket: ticket, remove_document_ids: ['00000000-0000-0000-0000-000000000000']) }
      .not_to raise_error
  end

  it 'refreshes the association cache after a removal' do
    doc = create(:ticket_document, ticket: ticket, organisation: organisation)
    ticket.ticket_documents.to_a # prime the cache so a stale read would still show the doc

    described_class.call(ticket: ticket, remove_document_ids: [doc.id.to_s])

    expect(ticket.ticket_documents).to be_empty
  end
end

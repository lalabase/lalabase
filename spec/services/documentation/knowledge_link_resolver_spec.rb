# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::KnowledgeLinkResolver — turns a lalabase:// link into its in-app
#       target, enforcing the tenant + project isolation.
# Type: Service spec.
# Why:  This is the security seam of the link resolver (the T6 rest): a doc page must
#       never resolve a link to a note/document from ANOTHER project or ANOTHER tenant,
#       and a miss must be indistinguishable from "target does not exist" (no oracle).
RSpec.describe Documentation::KnowledgeLinkResolver do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:repository) do
    create(:project_repository, project: project, organisation: organisation,
                                full_name: 'acme/handbook', default_branch: 'main')
  end
  let(:set) do
    create(:documentation_set, project: project, project_repository: repository)
  end

  subject(:resolver) { described_class.new(documentation_set: set) }

  before { ActsAsTenant.current_tenant = organisation }

  # A Document's title lives on its current_version; build one so target snapshots work.
  def create_document(title: 'A Document')
    doc = create(:document, project: project, organisation: organisation)
    version = create(:document_version, document: doc, organisation: organisation, title: title)
    doc.update!(current_version: version)
    doc
  end

  describe 'a resolvable note link' do
    it 'returns the note and its in-app path' do
      note = create(:note, project: project, organisation: organisation, title: 'Runbook')
      resolved = resolver.resolve("lalabase://note/#{note.id}")

      expect(resolved.target).to eq(note)
      expect(resolved.path).to eq(
        "/org/#{organisation.id}/projects/#{project.id}/notes/#{note.id}"
      )
    end
  end

  describe 'a resolvable document link (both target types resolve)' do
    it 'returns the document and its in-app path' do
      document = create_document
      resolved = resolver.resolve("lalabase://document/#{document.id}")

      expect(resolved.target).to eq(document)
      expect(resolved.path).to eq(
        "/org/#{organisation.id}/projects/#{project.id}/documents/#{document.id}"
      )
    end
  end

  describe 'isolation' do
    it 'does NOT resolve a note from another project of the same org (no cross-project leak)' do
      other_project = create(:project, organisation: organisation)
      foreign_note = create(:note, project: other_project, organisation: organisation)

      expect(resolver.resolve("lalabase://note/#{foreign_note.id}")).to be_nil
    end

    it 'does NOT resolve a note from another tenant (cross-tenant)' do
      other_org = create(:organisation)
      foreign_note = ActsAsTenant.with_tenant(other_org) do
        create(:note, project: create(:project, organisation: other_org), organisation: other_org)
      end

      expect(resolver.resolve("lalabase://note/#{foreign_note.id}")).to be_nil
    end

    it 'treats "unknown UUID" and "foreign project" identically (no existence oracle)' do
      other_project = create(:project, organisation: organisation)
      foreign_note = create(:note, project: other_project, organisation: organisation)

      unknown = resolver.resolve("lalabase://note/#{SecureRandom.uuid}")
      foreign = resolver.resolve("lalabase://note/#{foreign_note.id}")

      expect(unknown).to eq(foreign) # both nil — same observable result
    end
  end

  describe 'upper-case UUID (canonicalisation)' do
    it 'resolves a link whose UUID is written in upper case' do
      note = create(:note, project: project, organisation: organisation)
      resolved = resolver.resolve("lalabase://note/#{note.id.upcase}")
      expect(resolved.target).to eq(note)
    end
  end

  describe 'unresolvable shapes' do
    it 'returns nil for a malformed / foreign / unknown-type link' do
      expect(resolver.resolve('lalabase://note/not-a-uuid')).to be_nil
      expect(resolver.resolve("lalabase://ticket/#{SecureRandom.uuid}")).to be_nil
      expect(resolver.resolve('setup.md')).to be_nil
      expect(resolver.resolve(nil)).to be_nil
    end
  end

  describe 'batch resolution (resolve_all)' do
    it 'resolves many mixed-type links in one call and omits the unresolvable ones' do
      note = create(:note, project: project, organisation: organisation)
      document = create_document
      good_note = "lalabase://note/#{note.id}"
      good_doc  = "lalabase://document/#{document.id}"
      missing   = "lalabase://note/#{SecureRandom.uuid}"

      result = resolver.resolve_all([good_note, good_doc, missing, 'setup.md', '#anchor'])

      # Only the two resolvable urls are keys; a miss (missing/foreign/non-scheme) is absent.
      expect(result.keys).to contain_exactly(good_note, good_doc)
      expect(result[good_note].target).to eq(note)
      expect(result[good_doc].target).to eq(document)
    end

    it 'looks up each type in ONE query regardless of how many links of that type appear' do
      notes = Array.new(3) { create(:note, project: project, organisation: organisation) }
      urls = notes.map { |note| "lalabase://note/#{note.id}" }

      # A per-link find_by would issue three notes SELECTs (a classic N+1). The batch
      # resolver must issue exactly one, whatever the link count. Reverting resolve_all
      # to a per-link lookup turns this red.
      note_selects = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        note_selects += 1 if payload[:sql]&.match?(/FROM "notes"/)
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        resolver.resolve_all(urls)
      end

      expect(note_selects).to eq(1)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::GetDocument -- fetches one document as JSON with the text
#       of its CURRENT version (doc/assistent_wissen_kontext_plan.md, step 2).
# Type: Service spec.
# Why:  Beside the record-mode rules every read tool shares (see get_note_spec),
#       this one has three of its own: the reference names the DOCUMENT and the
#       tool reads its current version, naming it; the text is never extracted
#       here but read from the version, and its absence is reported in the same
#       four words a ticket's attachments use plus "no_version"; and a document
#       without a version still answers with a citation, so the answer stays gated.
RSpec.describe Lalabase::Tools::GetDocument do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }

  let(:actor) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant_documents(access, on: project)
    create(:project_permission, user: actor, project: on, documents_access: access)
  end

  def document_with(title: 'Angebot 2026', text: 'Position 1: Beratung', content_type: 'text/plain', on: project)
    document = create(:document, project: on, organisation: organisation, creator: actor)
    version = create(:document_version, document: document, organisation: organisation, title: title,
                                        document_version_file: Rack::Test::UploadedFile.new(
                                          StringIO.new('file bytes'), content_type, true, original_filename: 'angebot.txt'
                                        ))
    version.update_columns(plain_text_version: text)
    document.update!(current_version: version)
    document
  end

  def run(id, ctx: context)
    described_class.execute(args: { document_id: id }, context: ctx)
  end

  def payload(id, ctx: context)
    JSON.parse(run(id, ctx: ctx).content)
  end

  describe 'contract metadata' do
    it 'is a read tool, authorizes per record and requires an authenticated user' do
      expect(described_class.mutating?).to be false
      expect(described_class.authorization_mode).to eq(:record)
      expect(described_class.requires_actor?).to be true
    end

    it 'says in its description that the CURRENT version is what gets read' do
      expect(described_class.description).to match(/CURRENT version/)
      expect(described_class.description).to match(/no_version/)
    end
  end

  describe 'rights of the asking user' do
    let(:document) { document_with }

    it 'returns the document when the user may read it' do
      grant_documents(:read_only)

      expect(payload(document.id)).to include('id' => document.id, 'title' => 'Angebot 2026')
    end

    it 'refuses a document the user may not read instead of serialising it' do
      expect { run(document.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'refuses the document when only the notes area is readable' do
      create(:project_permission, user: actor, project: project, notes_access: 'read_only')

      expect { run(document.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'reports "no document" for a document in another project, never its data' do
      grant_documents(:read_only)
      foreign = document_with(title: 'Geheim', on: create(:project, organisation: organisation))

      result = run(foreign.id)

      expect(result).to be_empty
      expect(result.content).not_to include('Geheim')
    end
  end

  describe 'the current version' do
    before { grant_documents(:read_only) }

    it 'reads the text of the current version and names it' do
      document = document_with

      data = payload(document.id)

      expect(data['text_status']).to eq('available')
      expect(data['text']).to eq('Position 1: Beratung')
      expect(data['version']).to include('id' => document.current_version.id, 'file_name' => 'angebot.txt',
                                         'content_type' => 'text/plain')
      expect(data['versions_total']).to eq(1)
      expect(data['project']).to eq('id' => project.id, 'name' => project.name)
    end

    # The reference stays on the document; a newer current version is what the
    # next call reads, and the payload says which one it was.
    it 'follows the current version when it changes' do
      document = document_with(text: 'alt')
      newer = create(:document_version, document: document, organisation: organisation, title: 'Angebot v2')
      newer.update_columns(plain_text_version: 'neu')
      document.update!(current_version: newer)

      data = payload(document.id)

      expect(data['text']).to eq('neu')
      expect(data['version']['id']).to eq(newer.id)
      expect(data['versions_total']).to eq(2)
      expect(run(document.id).citations).to eq([Lalabase::Citations.document(newer)])
    end

    it 'cuts a long text at the limit, keeps the marker and reports the full length' do
      limit = described_class::MAX_TEXT_CHARS
      document = document_with(text: 'a' * (limit + 1))

      data = payload(document.id)

      expect(data['text_truncated']).to be true
      expect(data['text_length']).to eq(limit + 1)
      expect(data['text']).to end_with(described_class::TRUNCATION_MARKER)
    end

    # Review of #799: the description is free text too, and an uncapped one is
    # a way past the text limit -- a million characters there make a tool
    # result the Runner's budget refuses only AFTER letting it through.
    it 'cuts a long description as well, and says so' do
      limit = described_class::MAX_DESCRIPTION_CHARS
      document = document_with
      document.current_version.update_columns(description: 'd' * (limit + 1))

      data = payload(document.id)

      expect(data['description_truncated']).to be true
      expect(data['description'].length).to eq(limit + described_class::TRUNCATION_MARKER.length)
      expect(data['description']).to end_with(described_class::TRUNCATION_MARKER)
    end

    it 'leaves a short description whole' do
      document = document_with
      document.current_version.update_columns(description: 'kurz')

      expect(payload(document.id)).to include('description' => 'kurz', 'description_truncated' => false)
    end
  end

  # The four words of ExtractPlainTextProcessingService.text_status, plus the
  # fifth for a document without a version. ⚠️ Missing text is reported as
  # missing and never explained: NULL does not tell "not processed yet" from
  # "processing failed", so the tool must not claim either.
  describe 'text_status' do
    before { grant_documents(:read_only) }

    it 'says "empty" for a readable type that was read and held no text' do
      document = document_with(text: '', content_type: 'application/pdf')

      expect(payload(document.id)).to include('text_status' => 'empty', 'text' => nil)
    end

    it 'says "unavailable" for a readable type that has not been read out' do
      document = document_with(text: nil, content_type: 'application/pdf')

      expect(payload(document.id)).to include('text_status' => 'unavailable', 'text' => nil)
    end

    it 'says "unsupported" for a type we never read text from' do
      document = document_with(text: nil, content_type: 'image/png')

      expect(payload(document.id)).to include('text_status' => 'unsupported', 'text' => nil)
    end

    it 'says "no_version" for a document without a current version, and still cites it' do
      document = create(:document, project: project, organisation: organisation, creator: actor)

      result = run(document.id)
      data = JSON.parse(result.content)

      expect(data).to include('text_status' => 'no_version', 'version' => nil, 'title' => nil, 'text' => nil)
      expect(result.citations).to eq([Lalabase::Citations.document_record(document)])
    end
  end

  describe 'guards' do
    it 'rejects a non-UUID document_id before any query' do
      expect(run('nope').error).to match(/invalid document_id/)
    end

    it 'errors without a project or a scope' do
      bare = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: nil)

      expect(run(SecureRandom.uuid, ctx: bare).error).to match(/project context missing/)
    end
  end

  describe 'org-wide reach' do
    let(:reachable) { create(:project, organisation: organisation) }
    let(:elsewhere) { create(:project, organisation: organisation) }

    def org_context(only_project_id: nil, references: [])
      Lalabase::Tools::Context.new(
        actor: actor, organisation: organisation, project: nil,
        scope: Lalabase::Tools::Scope.new(organisation: organisation, actor: actor,
                                          only_project_id: only_project_id, references: references)
      )
    end

    let!(:readable_document) { document_with(title: 'Lesbar', on: reachable) }
    let!(:hidden_document)   { document_with(title: 'Verborgen', on: elsewhere) }

    before { grant_documents(:read_only, on: reachable) }

    it 'serves a document from a readable project and wears the documents reach' do
      result = run(readable_document.id, ctx: org_context)

      expect(JSON.parse(result.content)['title']).to eq('Lesbar')
      # Two projects exist here (`project` is lazy and never built in this branch).
      expect(result.coverage).to eq(searched: 1, total: 2)
    end

    it 'reports "no document" for a document in a project outside the reach' do
      result = run(hidden_document.id, ctx: org_context)

      expect(result).to be_empty
      expect(result.content).not_to include('Verborgen')
    end

    describe 'a reference outside the chip' do
      before { grant_documents(:read_only, on: elsewhere) }

      let(:scoped) do
        org_context(only_project_id: reachable.id,
                    references: [{ 'type' => 'Document', 'id' => hidden_document.id }])
      end

      it 'serves the referenced document by id, and says the answer read from outside' do
        result = run(hidden_document.id, ctx: scoped)

        expect(JSON.parse(result.content)['title']).to eq('Verborgen')
        expect(result.coverage).to include(outside: true)
      end

      it 'still refuses an unreferenced document in the same project' do
        sibling = document_with(title: 'Nachbar', on: elsewhere)

        result = run(sibling.id, ctx: scoped)

        expect(result).to be_empty
        expect(result.content).not_to include('Nachbar')
      end
    end
  end
end

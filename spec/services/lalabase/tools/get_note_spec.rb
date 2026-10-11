# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::GetNote -- fetches one note as JSON, addressed by UUID
#       (doc/assistent_wissen_kontext_plan.md, step 2).
# Type: Service spec.
# Why:  A record-mode tool hands back ONE record, so the per-record authorization
#       is the only thing standing between a guessed address and a foreign note.
#       Pinned here: requires_actor? is declared; a note outside the reach is
#       "not found", never data; a note the user may not read raises; the text is
#       the stored Markdown, capped with a marker and reported as capped; the
#       citation carries the notes area; and the reference fallback of E3 reaches
#       a referenced note outside the chip without opening its neighbours.
RSpec.describe Lalabase::Tools::GetNote do
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
  let(:note) do
    create(:note, project: project, organisation: organisation, creator: actor, title: 'Einarbeitung',
                  content: '<h2>Schritte</h2><ul><li>Zugang beantragen</li></ul>')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant_notes(access, on: project)
    create(:project_permission, user: actor, project: on, notes_access: access)
  end

  def run(id, ctx: context)
    described_class.execute(args: { note_id: id }, context: ctx)
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

    it 'requires the note_id in its advertised schema' do
      expect(described_class.input_schema[:required]).to eq(['note_id'])
      expect(described_class.description).to match(/text_truncated/)
    end
  end

  describe 'rights of the asking user' do
    it 'returns the note when the user may read it' do
      grant_notes(:read_only)

      expect(payload(note.id)).to include('id' => note.id, 'title' => 'Einarbeitung')
    end

    # Mutation probe: remove the authorize! call from #serve and this turns
    # green-with-data, i.e. red here.
    it 'refuses a note the user may not read instead of serialising it' do
      expect { run(note.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    # The notes area, not the tickets area: a ticket right must not open a note.
    it 'refuses the note when only the tickets area is readable' do
      create(:project_permission, user: actor, project: project, tickets_access: 'read_only')

      expect { run(note.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'reports "no note" for a note in another project, never its data' do
      grant_notes(:read_only)
      foreign = create(:note, project: create(:project, organisation: organisation), organisation: organisation,
                              creator: actor, title: 'Geheim')

      result = run(foreign.id)

      expect(result).to be_empty
      expect(result.content).to include('No note found')
      expect(result.content).not_to include('Geheim')
    end
  end

  describe 'the text' do
    before { grant_notes(:read_only) }

    it 'hands over the stored Markdown, and says so' do
      data = payload(note.id)

      expect(data['text_format']).to eq('markdown')
      expect(data['text']).to include('## Schritte').and include('Zugang beantragen')
      expect(data['text_truncated']).to be false
      expect(data['text_length']).to eq(data['text'].length)
    end

    it 'falls back to the plain text for a note without a Markdown body' do
      note.update_columns(markdown_body: nil, plain_text_version: 'Nur Klartext')

      data = payload(note.id)

      expect(data).to include('text_format' => 'plain', 'text' => 'Nur Klartext')
    end

    # The boundary in all three positions: one under, on it, one over. On the
    # limit nothing is cut and nothing claims to be. One example each, because
    # three tool calls in one example read as an N+1 to Prosopite.
    { -1 => false, 0 => false, 1 => true }.each do |offset, truncated|
      it "reports #{truncated ? 'a cut' : 'no cut'} for a text #{offset.zero? ? 'exactly on' : "#{offset} from"} the limit" do
        limit = described_class::MAX_TEXT_CHARS
        length = limit + offset
        note.update_columns(markdown_body: 'a' * length)

        data = payload(note.id)

        expect(data['text_truncated']).to be(truncated)
        expect(data['text_length']).to eq(length)
        if truncated
          expect(data['text']).to end_with(described_class::TRUNCATION_MARKER)
          expect(data['text'].length).to eq(limit + described_class::TRUNCATION_MARKER.length)
        else
          expect(data['text'].length).to eq(length)
        end
      end
    end

    it 'carries project, tags and dates' do
      note.update!(tag_list: 'onboarding, hr')

      data = payload(note.id)

      expect(data['project']).to eq('id' => project.id, 'name' => project.name)
      expect(data['tags']).to contain_exactly('onboarding', 'hr')
      expect(data['updated_at']).to be_present
    end
  end

  describe 'citations (the gate for other readers of the thread)' do
    it 'cites the fetched note with the notes area' do
      grant_notes(:read_only)

      expect(run(note.id).citations).to eq([Lalabase::Citations.note(note)])
    end

    it 'cites nothing when no note was found' do
      grant_notes(:read_only)

      expect(run(SecureRandom.uuid).citations).to eq([])
    end
  end

  describe 'guards' do
    it 'rejects a non-UUID note_id before any query' do
      result = run('not-a-uuid')

      expect(result.error).to match(/invalid note_id/)
    end

    it 'errors without a project or a scope' do
      bare = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: nil)

      expect(run(note.id, ctx: bare).error).to match(/project context missing/)
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

    let!(:readable_note) { create(:note, project: reachable, organisation: organisation, creator: actor, title: 'Lesbar') }
    let!(:hidden_note)   { create(:note, project: elsewhere, organisation: organisation, creator: actor, title: 'Verborgen') }

    before { grant_notes(:read_only, on: reachable) }

    it 'serves a note from a readable project and wears the notes reach' do
      result = run(readable_note.id, ctx: org_context)

      expect(JSON.parse(result.content)['title']).to eq('Lesbar')
      # Two projects exist here (`project` is lazy and never built in this branch).
      expect(result.coverage).to eq(searched: 1, total: 2)
    end

    it 'reports "no note" for a note in a project outside the reach' do
      result = run(hidden_note.id, ctx: org_context)

      expect(result).to be_empty
      expect(result.content).not_to include('Verborgen')
      # Two projects exist here (`project` is lazy and never built in this branch).
      expect(result.coverage).to eq(searched: 1, total: 2)
    end

    # E3: what the thread POINTS AT may be read even when the chip searches
    # elsewhere -- and only that. The sibling in the same project stays out.
    describe 'a reference outside the chip' do
      before { grant_notes(:read_only, on: elsewhere) }

      let(:scoped) do
        org_context(only_project_id: reachable.id, references: [{ 'type' => 'Note', 'id' => hidden_note.id }])
      end

      it 'serves the referenced note by id, and says the answer read from outside' do
        result = run(hidden_note.id, ctx: scoped)

        expect(JSON.parse(result.content)['title']).to eq('Verborgen')
        expect(result.coverage).to include(outside: true)
        expect(result.coverage).not_to include(chosen: reachable.name)
      end

      it 'still refuses an unreferenced note in the same project' do
        sibling = create(:note, project: elsewhere, organisation: organisation, creator: actor, title: 'Nachbar')

        result = run(sibling.id, ctx: scoped)

        expect(result).to be_empty
        expect(result.content).not_to include('Nachbar')
      end

      it 'carries no outside when nothing was read from beyond the reach' do
        result = run(readable_note.id, ctx: scoped)

        expect(result.coverage).not_to include(outside: true)
      end

      # The reference widens REACHABILITY, not rights: a referenced note the
      # asker may no longer read still refuses at the record.
      it 'still refuses a referenced note once the right is gone' do
        ProjectPermission.find_by(user: actor, project: elsewhere).update!(notes_access: 'no_access')

        expect(run(hidden_note.id, ctx: scoped)).to be_empty
      end
    end
  end
end

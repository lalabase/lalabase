# frozen_string_literal: true

require 'rails_helper'

# The meeting reader uses the same rights and explicit-reference fallback as knowledge tools.
RSpec.describe Lalabase::Tools::GetMeeting do
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
  let(:meeting) do
    create(:meeting, project: project, organisation: organisation, creator: actor, title: 'Einarbeitung',
                     notes: 'Entscheidung: Start im Mai.', transcript: 'Anna: Bleibt das Budget offen?')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant_meetings(access, on: project)
    create(:project_permission, user: actor, project: on, meetings_access: access)
  end

  def run(id, ctx: context)
    described_class.execute(args: { meeting_id: id }, context: ctx)
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

    it 'requires the meeting_id in its advertised schema' do
      expect(described_class.input_schema[:required]).to eq(['meeting_id'])
      expect(described_class.description).to match(/text_truncated/)
    end
  end

  describe 'rights of the asking user' do
    it 'returns the meeting when the user may read it' do
      grant_meetings(:read_only)

      expect(payload(meeting.id)).to include('id' => meeting.id, 'title' => 'Einarbeitung')
    end

    # Mutation probe: remove the authorize! call from #serve and this turns
    # green-with-data, i.e. red here.
    it 'refuses a meeting the user may not read instead of serialising it' do
      expect { run(meeting.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    # The meetings area, not the tickets area: a ticket right must not open a meeting.
    it 'refuses the meeting when only the tickets area is readable' do
      create(:project_permission, user: actor, project: project, tickets_access: 'read_only')

      expect { run(meeting.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'reports "no meeting" for a meeting in another project, never its data' do
      grant_meetings(:read_only)
      foreign = create(:meeting, project: create(:project, organisation: organisation), organisation: organisation,
                                 creator: actor, title: 'Geheim')

      result = run(foreign.id)

      expect(result).to be_empty
      expect(result.content).to include('No meeting found')
      expect(result.content).not_to include('Geheim')
    end
  end

  describe 'source data' do
    before { grant_meetings(:read_only) }

    {
      'notes alone' => ['## Entscheidung\nStart im Mai.', nil],
      'transcript alone' => [nil, 'Anna: Ist das Budget offen?'],
      'both sources' => ['Start im Mai.', 'Anna: Ist das Budget offen?'],
      'no content' => [nil, '']
    }.each do |label, (notes, transcript)|
      it "reads #{label} as separate sources without changing the meeting" do
        meeting.update!(notes: notes, transcript: transcript, generated_summary: 'Bestehender Abriss')
        original = meeting.attributes
        data = nil

        expect { data = payload(meeting.id) }
          .not_to(change { [MeetingAnalysis.count, Ticket.count, meeting.reload.attributes] })

        { 'notes' => notes, 'transcript' => transcript }.each do |key, value|
          expect(data[key]).to include('text' => value.to_s, 'text_length' => value.to_s.length,
                                       'text_format' => 'markdown', 'text_truncated' => false,
                                       'text_status' => value.present? ? 'available' : 'empty')
        end
        expect(meeting.reload.attributes).to eq(original)
        expect(meeting.summary_source).to eq(transcript.presence || notes.presence)
      end
    end

    it 'strips frontmatter independently from both sources' do
      meeting.update!(notes: "---\nprivate_id: notes\n---\nNotizen", transcript: "---\nprivate_id: transcript\n---\nWortlaut")

      data = payload(meeting.id)

      expect(data['notes']['text']).to eq('Notizen')
      expect(data['transcript']['text']).to eq('Wortlaut')
      expect(meeting.summary_source).to eq('Wortlaut')
    end

    %w[notes transcript].each do |source|
      [-1, 0, 1].each do |offset|
        it "reports the #{source} truncation at limit #{offset >= 0 ? '+' : ''}#{offset}" do
          length = described_class::MAX_TEXT_CHARS + offset
          meeting.update!(source => 'a' * length)

          data = payload(meeting.id).fetch(source)

          expect(data['text_length']).to eq(length)
          expect(data['text_truncated']).to eq(offset.positive?)
          expect(data['text']).to eq(offset.positive? ? 'a' * described_class::MAX_TEXT_CHARS + described_class::TRUNCATION_MARKER : 'a' * length)
        end
      end
    end

    it 'keeps space for both long sources and leaves the normal injection guard enabled' do
      meeting.update!(notes: 'N' * 20_000, transcript: 'T' * 20_000)
      result = run(meeting.id)
      data = JSON.parse(result.content)

      expect(data['notes']['text']).to start_with('NNN').and end_with(described_class::TRUNCATION_MARKER)
      expect(data['transcript']['text']).to start_with('TTT').and end_with(described_class::TRUNCATION_MARKER)
      expect(result.fence_guarded?).to be false
      expect(result.content.length).to be < Lalabase::Tools::Runner::DEFAULT_MAX_TOOL_RESULT_CHARS
    end

    it 'reads unindexed meetings with participant names and time, but no saved analyses' do
      meeting.update!(create_embeddings: false, duration_minutes: 45)
      create(:meeting_participant, meeting: meeting, display_name: 'Anna Ananas')
      create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: create(:user),
                                content: 'PRIVATE ANALYSIS SECRET')

      data = payload(meeting.id)

      expect(data).to include('participants' => ['Anna Ananas'], 'participants_truncated' => false,
                              'occurred_at' => meeting.occurred_at.iso8601, 'duration_minutes' => 45)
      expect(data.to_json).not_to include('PRIVATE ANALYSIS SECRET', 'generated_summary')
      expect(meeting.reload.create_embeddings).to be false
    end

    it 'bounds free-form metadata and explicitly marks an incomplete participant list' do
      meeting.update!(title: 'T' * 500)
      Prosopite.pause do
        (described_class::MAX_PARTICIPANTS + 1).times do |i|
          create(:meeting_participant, meeting: meeting, display_name: "#{i} #{'N' * 500}")
        end
      end

      data = payload(meeting.id)

      expect(data['title']).to end_with(described_class::TRUNCATION_MARKER)
      expect(data['participants'].size).to eq(described_class::MAX_PARTICIPANTS)
      expect(data['participants_truncated']).to be true
      expect(data['participants']).to all(end_with(described_class::TRUNCATION_MARKER))
    end
  end

  describe 'citations (the gate for other readers of the thread)' do
    it 'uses the existing meeting navigation target' do
      grant_meetings(:read_only)
      citation = run(meeting.id).citations.first.stringify_keys

      expect(Lalabase::Citations.target_of(citation)).to include(type: 'meeting', id: meeting.id)
      expect(Lalabase::CitationLink.path_for(citation, organisation: organisation))
        .to eq(Rails.application.routes.url_helpers.organisation_project_meeting_path(organisation, project, meeting))
    end

    it 'cites the fetched meeting with the meetings area' do
      grant_meetings(:read_only)

      expect(run(meeting.id).citations).to eq([Lalabase::Citations.meeting(meeting)])
    end

    it 'cites nothing when no meeting was found' do
      grant_meetings(:read_only)

      expect(run(SecureRandom.uuid).citations).to eq([])
    end
  end

  describe 'guards' do
    it 'rejects a non-UUID meeting_id before any query' do
      result = run('not-a-uuid')

      expect(result.error).to match(/invalid meeting_id/)
    end

    it 'errors without a project or a scope' do
      bare = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: nil)

      expect(run(meeting.id, ctx: bare).error).to match(/project context missing/)
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

    let!(:readable_meeting) { create(:meeting, project: reachable, organisation: organisation, creator: actor, title: 'Lesbar') }
    let!(:hidden_meeting)   { create(:meeting, project: elsewhere, organisation: organisation, creator: actor, title: 'Verborgen') }

    before { grant_meetings(:read_only, on: reachable) }

    it 'refuses a foreign organisation even without an ambient tenant' do
      foreign_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(foreign_org) do
        create(:membership, organisation: foreign_org, user: actor, role: create(:role, organisation: foreign_org), active: true)
        create(:meeting, organisation: foreign_org, project: create(:project, organisation: foreign_org),
                         creator: actor, title: 'Foreign secret')
      end
      ActsAsTenant.with_tenant(foreign_org) { grant_meetings(:read_only, on: foreign.project) }
      foreign_context = Lalabase::Tools::Context.new(actor: actor, organisation: foreign_org, project: nil,
                                                     scope: Lalabase::Tools::Scope.new(organisation: foreign_org, actor: actor))
      expect(ActsAsTenant.without_tenant { payload(foreign.id, ctx: foreign_context)['title'] }).to eq('Foreign secret')
      ctx = org_context(references: [{ 'type' => 'Meeting', 'id' => foreign.id }])

      result = ActsAsTenant.without_tenant { run(foreign.id, ctx: ctx) }

      expect(result).to be_empty
      expect(result.content).not_to include('Foreign secret')
    end

    it 'does not resolve or read an archived meeting reference' do
      reachable.update!(archived_at: Time.current)
      ctx = org_context(references: [{ 'type' => 'Meeting', 'id' => readable_meeting.id }])

      expect(run(readable_meeting.id, ctx: ctx)).to be_empty
      expect(ctx.scope.references).to be_empty
    end

    it 'serves a meeting from a readable project and wears the meetings reach' do
      result = run(readable_meeting.id, ctx: org_context)

      expect(JSON.parse(result.content)['title']).to eq('Lesbar')
      # Two projects exist here (`project` is lazy and never built in this branch).
      expect(result.coverage).to eq(searched: 1, total: 2)
    end

    it 'reports "no meeting" for a meeting in a project outside the reach' do
      result = run(hidden_meeting.id, ctx: org_context)

      expect(result).to be_empty
      expect(result.content).not_to include('Verborgen')
      # Two projects exist here (`project` is lazy and never built in this branch).
      expect(result.coverage).to eq(searched: 1, total: 2)
    end

    # E3: what the thread POINTS AT may be read even when the chip searches
    # elsewhere -- and only that. The sibling in the same project stays out.
    describe 'a reference outside the chip' do
      before { grant_meetings(:read_only, on: elsewhere) }

      let(:scoped) do
        org_context(only_project_id: reachable.id, references: [{ 'type' => 'Meeting', 'id' => hidden_meeting.id }])
      end

      it 'serves the referenced meeting by id, and says the answer read from outside' do
        result = run(hidden_meeting.id, ctx: scoped)

        expect(JSON.parse(result.content)['title']).to eq('Verborgen')
        expect(result.coverage).to include(outside: true)
        expect(result.coverage).not_to include(chosen: reachable.name)
      end

      it 'resolves only reference metadata and reads current sources when asked' do
        reference = scoped.scope.references.sole
        expect(reference.attribute_names).to match_array(%w[id organisation_id project_id title occurred_at])
        expect(reference.project.id).to eq(elsewhere.id)
        hidden_meeting.update!(notes: 'Neue Entscheidung', transcript: 'Neuer Wortlaut')

        data = payload(hidden_meeting.id, ctx: scoped)

        expect(data['notes']['text']).to eq('Neue Entscheidung')
        expect(data['transcript']['text']).to eq('Neuer Wortlaut')
      end

      it 'returns no content if the resolved meeting has since been deleted' do
        expect(scoped.scope.references.map(&:id)).to include(hidden_meeting.id)
        hidden_meeting.destroy!

        expect(run(hidden_meeting.id, ctx: scoped)).to be_empty
      end

      it 'returns no content if the resolved meeting project has since been archived' do
        expect(scoped.scope.references.map(&:id)).to include(hidden_meeting.id)
        elsewhere.update!(archived_at: Time.current)

        expect(run(hidden_meeting.id, ctx: scoped)).to be_empty
      end

      it 'still refuses an unreferenced meeting in the same project' do
        sibling = create(:meeting, project: elsewhere, organisation: organisation, creator: actor, title: 'Nachbar')

        result = run(sibling.id, ctx: scoped)

        expect(result).to be_empty
        expect(result.content).not_to include('Nachbar')
      end

      it 'carries no outside when nothing was read from beyond the reach' do
        result = run(readable_meeting.id, ctx: scoped)

        expect(result.coverage).not_to include(outside: true)
      end

      # The reference widens REACHABILITY, not rights: a referenced meeting the
      # asker may no longer read still refuses at the record.
      it 'still refuses a referenced meeting once the right is gone' do
        ProjectPermission.find_by(user: actor, project: elsewhere).update!(meetings_access: 'no_access')

        expect(run(hidden_meeting.id, ctx: scoped)).to be_empty
      end

      it 'rechecks record authorization even after the reference was resolved' do
        expect(scoped.scope.references.map(&:id)).to include(hidden_meeting.id)
        ProjectPermission.find_by(user: actor, project: elsewhere).update!(meetings_access: 'no_access')

        expect { run(hidden_meeting.id, ctx: scoped) }.to raise_error(Pundit::NotAuthorizedError)
      end
    end
  end
end

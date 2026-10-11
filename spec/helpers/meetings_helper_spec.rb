# frozen_string_literal: true

require 'rails_helper'

# The linked-tickets turbo-frame id is a contract shared by the section partial and
# MeetingTicketLinksController. This unit pins its exact value, so an accidental
# rename surfaces as one clear failure here rather than a silently broken refresh.
RSpec.describe MeetingsHelper, type: :helper do
  let(:organisation) { create(:organisation) }

  # A tenant must be set before building an acts_as_tenant record (require_tenant).
  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe '#meeting_ticket_links_frame_id' do
    it 'derives a stable, per-meeting frame id' do
      meeting = build_stubbed(:meeting, organisation: organisation)
      expect(helper.meeting_ticket_links_frame_id(meeting)).to eq("ticket_links_meeting_#{meeting.id}")
    end
  end

  describe '#meeting_analyses_list_id' do
    it 'uses the shared inner results target' do
      meeting = build_stubbed(:meeting)
      expect(helper.meeting_analyses_list_id(meeting)).to eq("analyses_list_meeting_#{meeting.id}")
    end
  end

  # Notes/transcript are Markdown pasted from AI transcript tools. The helper PREPARES
  # that source (frontmatter strip, speaker labels); the safe render belongs to
  # Neo::MarkdownPreviewComponent, which every display site goes through — its own spec
  # covers the allowlist. Storage stays raw either way.
  describe '#meeting_markdown_source' do
    it 'strips a leading frontmatter block and keeps the Markdown as source' do
      source = helper.meeting_markdown_source("---\nid: SENTINEL\n---\n## Themen\n\nLos.")

      expect(source).to include('## Themen')
      expect(source).not_to include('SENTINEL')
    end

    it 'bolds the speaker labels it was given, and only those' do
      source = helper.meeting_markdown_source("Guido: Los.\nFremde: Auch.", speakers: ['Guido'])

      expect(source).to include('**Guido:**')
      expect(source).to include('Fremde: Auch.')
    end

    it 'leaves the text alone when no speakers are passed' do
      expect(helper.meeting_markdown_source('Guido: Los.')).to eq('Guido: Los.')
    end
  end

  # The header "Abriss": summary if present, else notes — both flattened to plain
  # text (frontmatter strip → StripDown) so no markdown syntax leaks into the excerpt.
  describe '#meeting_excerpt_source' do
    it 'prefers the generated summary when present' do
      meeting = build_stubbed(:meeting, organisation: organisation,
                                        generated_summary: 'LLM Kurzfassung.', notes: 'Notiz.')
      expect(helper.meeting_excerpt_source(meeting)).to include('LLM Kurzfassung.')
    end

    it 'falls back to the notes as plain text, without frontmatter or ##/** syntax' do
      meeting = build_stubbed(:meeting, organisation: organisation, generated_summary: '',
                                        notes: "---\nid: SENTINEL\n---\n## Titel\n\n**wichtig** Punkt.")
      excerpt = helper.meeting_excerpt_source(meeting)
      expect(excerpt).to include('Titel', 'wichtig', 'Punkt.')
      expect(excerpt).not_to include('SENTINEL', '##', '**')
    end

    it 'returns a blank string when there is neither summary nor notes' do
      meeting = build_stubbed(:meeting, organisation: organisation, generated_summary: '', notes: nil)
      expect(helper.meeting_excerpt_source(meeting)).to eq('')
    end
  end

  # Participant chip identity (Nachtrag: Teilnehmer-Kennzeichnung). The type is
  # derived from user_id + the project's permitted_user_ids Set (loaded ONCE by the
  # caller, never per chip); the style map is the single source both chip render
  # sites share so their optik can never drift.
  describe '#meeting_participant_type' do
    let(:member_id) { SecureRandom.uuid }
    let(:permitted) { Set[member_id] }

    it 'is :project_member when the linked user has project access' do
      participant = double(user_id: member_id)
      expect(helper.meeting_participant_type(participant, permitted)).to eq(:project_member)
    end

    it 'is :org_member when a linked user is NOT in the project permitted set' do
      participant = double(user_id: SecureRandom.uuid)
      expect(helper.meeting_participant_type(participant, permitted)).to eq(:org_member)
    end

    it 'is :external when the participant has no linked user' do
      participant = double(user_id: nil)
      expect(helper.meeting_participant_type(participant, permitted)).to eq(:external)
    end
  end

  describe '#meeting_participant_chip_style' do
    it 'maps each type to a distinct NeoTag variant, icon and translated tooltip' do
      project  = helper.meeting_participant_chip_style(:project_member)
      org      = helper.meeting_participant_chip_style(:org_member)
      external = helper.meeting_participant_chip_style(:external)

      # Distinct variants (the D-decision: primary / info / neutral).
      expect([project[:variant], org[:variant], external[:variant]]).to eq(%i[primary info neutral])
      # Every state carries an icon and a real (non-missing) translation.
      expect([project[:icon], org[:icon], external[:icon]]).to all(be_present)
      expect(project[:title]).to eq(I18n.t('views.organisations.meetings.shared.participant_type.project_member'))
      expect(external[:title]).not_to match(/translation missing/i)
    end

    it 'falls back to the external style for an unknown type (never raises)' do
      expect(helper.meeting_participant_chip_style(:bogus)[:variant]).to eq(:neutral)
    end
  end

  # Search/index status derivation (Meeting-Such-Status): drives the detail-header
  # badge (_search_status). Reads create_embeddings + embeddings_creation_flag;
  # the badge always renders from a full meeting row, so no narrowed-select guard
  # is needed.
  describe '#meeting_search_status' do
    def status_for(create_embeddings:, flag:, ai_available: true)
      meeting = build_stubbed(:meeting, organisation: organisation,
                                        create_embeddings: create_embeddings,
                                        embeddings_creation_flag: flag)
      helper.meeting_search_status(meeting, ai_available: ai_available)
    end

    it 'is :off while the opt-in is disabled' do
      expect(status_for(create_embeddings: false, flag: nil)).to eq(:off)
      # Even a lingering true flag never overrides a disabled opt-in.
      expect(status_for(create_embeddings: false, flag: true)).to eq(:off)
    end

    it 'is :searchable when opted in and the flag confirms indexing' do
      expect(status_for(create_embeddings: true, flag: true)).to eq(:searchable)
    end

    it 'is :failed when opted in and the service recorded an error (flag false)' do
      expect(status_for(create_embeddings: true, flag: false)).to eq(:failed)
    end

    it 'is :processing when opted in, pending, and AI is usable' do
      expect(status_for(create_embeddings: true, flag: nil, ai_available: true)).to eq(:processing)
    end

    it 'is :waiting_ai when opted in, pending, and AI is not usable' do
      expect(status_for(create_embeddings: true, flag: nil, ai_available: false)).to eq(:waiting_ai)
    end
  end

  describe '#meeting_search_status_style' do
    it 'resolves each known status and falls back to :off for unknown ones' do
      expect(helper.meeting_search_status_style(:searchable)[:variant]).to eq(:success)
      expect(helper.meeting_search_status_style('failed')[:icon]).to eq('exclamation-triangle-fill')
      expect(helper.meeting_search_status_style(:processing)[:animated]).to be(true)
      expect(helper.meeting_search_status_style(:bogus)).to eq(MeetingsHelper::SEARCH_STATUS_STYLES[:off])
    end
  end
end

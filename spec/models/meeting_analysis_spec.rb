# frozen_string_literal: true

require 'rails_helper'

# MeetingAnalysis — the Post-pattern visibility model for Slice 7a.
#
# Intent: prove the visibility invariant that everything else (policy scope, list
# filter, Slice 7b fragment filter) leans on — a private analysis is visible ONLY
# to its creator, a published one to everyone; the callback keeps visible_to_user
# consistent so "private ⇒ visible_to set" can never be violated. Plus the derived
# pipeline contracts (plain_text_version, create_embeddings) and the staleness valve.
RSpec.describe MeetingAnalysis do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:creator) { create(:user, organisation: organisation) }
  let(:other) { create(:user, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: creator) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    it 'requires prompt_title and prompt_snapshot' do
      analysis = build(:meeting_analysis, meeting: meeting, creator: creator, prompt_title: nil, prompt_snapshot: nil)
      expect(analysis).to be_invalid
      expect(analysis.errors[:prompt_title]).to be_present
      expect(analysis.errors[:prompt_snapshot]).to be_present
    end
  end

  describe 'visibility callback (private ⇒ creator, public ⇒ nil)' do
    it 'sets visible_to_user to the creator on a private analysis' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, is_private: true)
      expect(analysis.visible_to_user_id).to eq(creator.id)
    end

    it 'nils visible_to_user on a public analysis' do
      analysis = create(:meeting_analysis, :published, meeting: meeting, creator: creator)
      expect(analysis.visible_to_user_id).to be_nil
    end

    it 'nils visible_to_user when a private analysis is published (flip)' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, is_private: true)
      analysis.update!(is_private: false)
      expect(analysis.visible_to_user_id).to be_nil
    end

    it 'restores visible_to_user to the creator when re-privatised' do
      analysis = create(:meeting_analysis, :published, meeting: meeting, creator: creator)
      analysis.update!(is_private: true)
      expect(analysis.visible_to_user_id).to eq(creator.id)
    end
  end

  describe 'consistency validation' do
    it 'rejects a private analysis with no visible_to_user (creator missing)' do
      analysis = build(:meeting_analysis, meeting: meeting, creator: nil, is_private: true, visible_to_user: nil)
      expect(analysis).to be_invalid
      expect(analysis.errors[:visible_to_user]).to be_present
    end

    # The set_visible_to_user_on_private callback normally nils visible_to_user on a
    # public analysis (making this state unreachable via save); this asserts the
    # defence-in-depth validation itself still rejects it if the callback is bypassed.
    it 'rejects a public analysis that still names a visible_to_user (defence in depth)' do
      analysis = build(:meeting_analysis, :published, meeting: meeting, creator: creator)
      analysis.visible_to_user = other
      analysis.send(:private_visibility_consistency)
      expect(analysis.errors[:visible_to_user]).to be_present
    end
  end

  describe '.visible_to (the shared filter)' do
    let!(:my_private) { create(:meeting_analysis, meeting: meeting, creator: creator, is_private: true) }
    let!(:their_private) { create(:meeting_analysis, meeting: meeting, creator: other, is_private: true) }
    let!(:published) { create(:meeting_analysis, :published, meeting: meeting, creator: other) }

    it 'returns the creator their own private analysis and the published one, NOT the foreign private one' do
      visible = described_class.visible_to(creator)
      expect(visible).to include(my_private, published)
      expect(visible).not_to include(their_private)
    end

    it 'shows another meetings reader only the published analysis' do
      visible = described_class.visible_to(other)
      expect(visible).to include(their_private, published)
      expect(visible).not_to include(my_private)
    end
  end

  describe '#visible_to?' do
    it 'is true for everyone on a public analysis' do
      analysis = create(:meeting_analysis, :published, meeting: meeting, creator: creator)
      expect(analysis.visible_to?(other)).to be(true)
      expect(analysis.visible_to?(nil)).to be(true)
    end

    it 'is true only for the creator on a private analysis' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, is_private: true)
      expect(analysis.visible_to?(creator)).to be(true)
      expect(analysis.visible_to?(other)).to be(false)
      expect(analysis.visible_to?(nil)).to be(false)
    end
  end

  describe 'derived pipeline contracts' do
    it 'exposes plain_text_version as the content (method, not a column)' do
      analysis = build(:meeting_analysis, content: 'ANALYSE-TEXT')
      expect(analysis.plain_text_version).to eq('ANALYSE-TEXT')
      expect(described_class.column_names).not_to include('plain_text_version')
    end

    it 'only allows embeddings when public AND released to search (E18)' do
      expect(build(:meeting_analysis, is_private: true, include_in_search: true).create_embeddings?).to be(false)
      expect(build(:meeting_analysis, is_private: false, include_in_search: false).create_embeddings?).to be(false)
      expect(build(:meeting_analysis, is_private: false, include_in_search: true).create_embeddings?).to be(true)
    end
  end

  describe '#generation_running? (staleness valve)' do
    it 'is running while the flag is set and recently touched' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: true)
      expect(analysis.generation_running?).to be(true)
    end

    it 'is not running once the flag is stale (self-healing)' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: true)
      # Directly age updated_at past the window — a normal update would touch it back.
      analysis.update_column(:updated_at, (described_class::STALE_AFTER + 1.minute).ago)
      expect(analysis.generation_running?).to be(false)
    end

    it 'is not running without the flag' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: false)
      expect(analysis.generation_running?).to be(false)
    end
  end

  # "Aufgaben ableiten" became an actionable ticket-suggestion mode, so the old prose
  # "To-dos" example (it produced an unreadable wall) must stay gone from BOTH the
  # model's chip list and the locales -- a stray locale key would silently revive it.
  describe 'SUGGESTED_PROMPT_KEYS' do
    it 'no longer offers the prose action_items example, in code or in either locale' do
      expect(described_class::SUGGESTED_PROMPT_KEYS).not_to include('action_items')
      %i[de en].each do |locale|
        expect(I18n.exists?('views.organisations.meetings.analyses.suggestions.action_items.label', locale)).to be(false)
      end
    end
  end

  describe 'legacy job completion broadcast' do
    before { create(:project_permission, user: creator, project: meeting.project, meetings_access: 'read_write') }

    it 'replaces only the result list so the assistant entry remains mounted' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: true)
      expect(analysis).to receive(:broadcast_replace_to).with(
        meeting, creator, :analyses,
        hash_including(
          target: "analyses_list_meeting_#{meeting.id}",
          partial: 'organisations/meetings/analyses_list',
          locals: hash_including(meeting: meeting, can_write: true, can_rerun: false)
        )
      )

      analysis.update!(creation_flag: false, content: 'Fertiges Ergebnis')
    end

    # The job has no assistant_available? helper, so the model asks the gate for the
    # CREATOR itself. Closed above (flag off by default), open here.
    it 'offers the retry to a creator whose assistant gate is open' do
      organisation.update!(assistant_enabled: true)
      role = Membership.find_by!(user: creator, organisation: organisation).role
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: true)
      expect(analysis).to receive(:broadcast_replace_to).with(
        meeting, creator, :analyses, hash_including(locals: hash_including(can_rerun: true))
      )

      analysis.update!(creation_flag: false, creation_error: 'kaputt')
    end

    # A job loads the analysis and its meeting, a move commits (Actors::MoveMeeting)
    # while the model answers, the job finishes on its stale copy. The creator
    # reads meetings only in the old project and gets nothing pushed.
    it 'pushes nothing once the meeting is in a project the creator cannot read' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: true)
      stale = described_class.find(analysis.id)
      stale.meeting.project
      elsewhere = create(:project, organisation: organisation)
      Meeting.where(id: meeting.id).update_all(project_id: elsewhere.id)

      expect(stale).not_to receive(:broadcast_replace_to)
      stale.update!(creation_flag: false, content: 'Ergebnis nach dem Umzug')
    end

    it 'still pushes to a creator who reads meetings in the new project' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator, creation_flag: true)
      stale = described_class.find(analysis.id)
      stale.meeting.project
      elsewhere = create(:project, organisation: organisation)
      create(:project_permission, user: creator, project: elsewhere, meetings_access: 'read_only')
      Meeting.where(id: meeting.id).update_all(project_id: elsewhere.id)

      expect(stale).to receive(:broadcast_replace_to).with(meeting, creator, :analyses,
                                                           hash_including(locals: hash_including(can_write: false)))
      stale.update!(creation_flag: false, content: 'Ergebnis nach dem Umzug')
    end
  end

  # Standalone destroy purge (embedding v2 PR 2, Delete-Matrix §3.5 row 7): destroying
  # an analysis on its OWN — not only via the meeting-destroy cascade — must purge its
  # fragments' sidecar rows synchronously. The fragments die via a callback-free
  # dependent: :delete_all, so the before_destroy prepend callback is the ONLY thing
  # that removes the sidecar rows (PII data class: no retrievable trace of a deleted
  # analysis). The prepend ordering is load-bearing — the callback must run BEFORE the
  # dependent delete_all removes the fragment ids its subselect needs, so this test
  # breaks if someone drops `prepend: true`.
  describe '#destroy sidecar purge (PII)' do
    it 'purges the sidecar rows of its fragments synchronously' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: creator)
      fragment = create(:fragment, fragmentable: analysis, organisation: organisation)
      sidecar  = create(:content_embedding, embeddable: fragment, organisation: organisation)

      expect { analysis.destroy }
        .to change(Fragment, :count).by(-1)
        .and change(ContentEmbedding, :count).by(-1)
      expect(ContentEmbedding.exists?(sidecar.id)).to be(false)
    end
  end
end

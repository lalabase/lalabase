# frozen_string_literal: true

require 'rails_helper'

# Actors::SaveMeetingAnalysis — the meeting-analysis write seam (Tier 1).
# Intent per describe:
#  - create: snapshots the chosen prompt (library OR free text), marks the run
#    pending, and enqueues the async LLM job after commit; optionally saves a
#    free-text prompt to the org library.
#  - flip: toggles private/published, meeting-scoped lookup (1A) — a foreign id
#    is a clean failure, never a raise-through.
RSpec.describe Actors::SaveMeetingAnalysis do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user, organisation: organisation) }
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: user, transcript: 'Some text')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    allow(Meetings::AnalysisJob).to receive(:perform_later)
    allow(EmbeddingProcessingJob).to receive(:perform_later)
  end

  after { ActsAsTenant.current_tenant = nil }

  # Top-level (was local to the 7b block) because the rerun block needs it too — a second
  # copy would be the kind of duplication that drifts.
  def frag_for(analysis)
    create(:fragment, fragmentable: analysis, organisation: organisation,
                      plain_text_content: 'analyse fragment')
  end

  describe 'create' do
    it 'snapshots a library prompt, marks the run pending, and enqueues the job' do
      prompt = create(:analysis_prompt, organisation: organisation, creator: user,
                                        title: 'Protokoll', prompt_text: 'Fasse Entscheidungen zusammen.')

      result = described_class.call(meeting: meeting, current_user: user,
                                    params: { analysis_prompt_id: prompt.id })

      expect(result.success).to be(true)
      analysis = result.resource
      expect(analysis.prompt_title).to eq('Protokoll')
      expect(analysis.prompt_snapshot).to eq('Fasse Entscheidungen zusammen.')
      expect(analysis.analysis_prompt).to eq(prompt)
      expect(analysis.creator).to eq(user)
      expect(analysis).to be_is_private
      expect(analysis.creation_flag).to be(true)
      expect(Meetings::AnalysisJob).to have_received(:perform_later).with(analysis_id: analysis.id)
    end

    it 'snapshots a free-text prompt and derives a title, without a library link' do
      result = described_class.call(meeting: meeting, current_user: user,
                                    params: { prompt_text: "Redigiere das Gespräch\nEntferne Persönliches." })

      analysis = result.resource
      expect(result.success).to be(true)
      expect(analysis.analysis_prompt).to be_nil
      expect(analysis.prompt_snapshot).to eq("Redigiere das Gespräch\nEntferne Persönliches.")
      expect(analysis.prompt_title).to eq('Redigiere das Gespräch')
    end

    it 'saves the free-text prompt to the org library when asked' do
      result = nil
      expect do
        result = described_class.call(meeting: meeting, current_user: user,
                                      params: { prompt_text: 'Ein wiederverwendbarer Prompt.', save_as_template: '1' })
      end.to change(AnalysisPrompt, :count).by(1)

      # Review of #363, finding 5: .last on a UUID key without
      # implicit_order_column is only deterministic as long as the example creates
      # exactly one row. The actor returns the record, so use it.
      template = result.resource.analysis_prompt
      expect(template.prompt_text).to eq('Ein wiederverwendbarer Prompt.')
      expect(template.creator).to eq(user)
    end

    it 'fails (no enqueue) when neither a library pick nor free text is given' do
      result = described_class.call(meeting: meeting, current_user: user, params: {})

      expect(result.success).to be(false)
      expect(Meetings::AnalysisJob).not_to have_received(:perform_later)
      expect(meeting.meeting_analyses.count).to eq(0)
    end

    # "Default-als-Vertrag", and at the same time 4A at birth: create sets is_private explicitly
    # but leaves include_in_search to the DB default (FALSE) — the actor never mentions the
    # column. If that default ever flipped to TRUE, every brand-new analysis would be
    # private AND search-released, i.e. exactly the state the flip guard exists to prevent,
    # and no other spec would notice. Deliberately asserted on the actor's own result, not
    # via the factory (the factory does not set the column either).
    it 'starts private, NOT search-released, and therefore unembeddable (DB default is the contract)' do
      result = described_class.call(meeting: meeting, current_user: user,
                                    params: { prompt_text: 'Fasse zusammen.' })

      analysis = result.resource
      expect(analysis).to be_is_private
      expect(analysis.include_in_search).to be(false)
      expect(analysis.create_embeddings?).to be(false)
      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    # Boundary at DERIVED_TITLE_LIMIT (n / n+1). A single "obviously far too long" example
    # would survive both truncate(LIMIT) → truncate(LIMIT + 1) and a dropped truncate, so the
    # limit itself is the interesting input. The pair also pins the asymmetry that matters:
    # the TITLE is shortened for display, the SNAPSHOT must keep the exact LLM input.
    it 'keeps a derived title of exactly DERIVED_TITLE_LIMIT characters intact' do
      text = 'A' * described_class::DERIVED_TITLE_LIMIT

      result = described_class.call(meeting: meeting, current_user: user, params: { prompt_text: text })

      expect(result.resource.prompt_title).to eq(text)
    end

    it 'truncates a derived title one character over the limit, leaving the snapshot full' do
      limit = described_class::DERIVED_TITLE_LIMIT
      text = 'A' * (limit + 1)

      result = described_class.call(meeting: meeting, current_user: user, params: { prompt_text: text })

      expect(result.resource.prompt_title.length).to eq(limit)
      expect(result.resource.prompt_title).to end_with('...')
      expect(result.resource.prompt_snapshot).to eq(text)
    end

    # template_title lets the user name the saved template differently from the analysis's
    # own derived title. Untested until now — and it is the only place where the two titles
    # may legitimately diverge, so a refactor that collapses them would go unnoticed.
    it 'uses template_title for the saved template while the analysis keeps its derived title' do
      result = described_class.call(meeting: meeting, current_user: user,
                                    params: { prompt_text: 'Ein wiederverwendbarer Prompt.',
                                              save_as_template: '1', template_title: 'Mein Vorlagenname' })

      template = result.resource.analysis_prompt
      expect(template.title).to eq('Mein Vorlagenname')
      expect(template.organisation).to eq(meeting.organisation)
      expect(result.resource.prompt_title).to eq('Ein wiederverwendbarer Prompt.')
    end

    # Kills `.presence ||` → `||`: a whitespace-only template_title is not a name.
    it 'falls back to the derived title when template_title is blank' do
      result = described_class.call(meeting: meeting, current_user: user,
                                    params: { prompt_text: 'Fasse zusammen.', save_as_template: '1',
                                              template_title: '   ' })

      expect(result.resource.analysis_prompt.title).to eq('Fasse zusammen.')
    end

    # Atomicity of the TWO writes (BaseActor wraps #perform in one transaction):
    # resolve_prompt creates the template BEFORE the analysis is saved, so a failing analysis
    # must take the template with it — otherwise a user retrying after an error collects
    # orphan templates. A nil current_user is the cheapest REACHABLE way to make the second
    # write fail: the model derives visible_to_user from the creator, and
    # private_visibility_consistency then rejects a private analysis without one.
    # Breaks if create_template is ever moved out of the transaction.
    it 'rolls the saved template back when the analysis itself fails to save' do
      expect do
        described_class.call(meeting: meeting, current_user: nil,
                             params: { prompt_text: 'Ein Prompt.', save_as_template: '1' })
      end.not_to change(AnalysisPrompt, :count)

      expect(meeting.meeting_analyses.count).to eq(0)
    end

    it 'fails for a prompt id from another organisation (tenant-scoped lookup)' do
      other_org = create(:organisation)
      foreign_prompt = ActsAsTenant.with_tenant(other_org) do
        create(:analysis_prompt, organisation: other_org, creator: create(:user, organisation: other_org))
      end

      result = described_class.call(meeting: meeting, current_user: user,
                                    params: { analysis_prompt_id: foreign_prompt.id })

      expect(result.success).to be(false)
      expect(Meetings::AnalysisJob).not_to have_received(:perform_later)
    end
  end

  # The third branch of #perform (params[:rerun]) — re-run a FAILED analysis on its FROZEN
  # snapshot: no new row, no prompt re-selection. This branch had no unit coverage at all
  # (only an end-to-end request spec), so its contract was entirely unpinned.
  describe 'rerun' do
    it 'clears the previous error, marks the run pending again, and re-enqueues on the SAME row' do
      failed = create(:meeting_analysis, meeting: meeting, creator: user,
                                         creation_flag: false, creation_error: 'Timeout beim Provider')
      # Captured, NOT compared against the factory's literal string — otherwise a factory
      # edit turns this red for a reason that has nothing to do with the rerun.
      snapshot_before = failed.prompt_snapshot

      expect do
        expect(described_class.call(meeting: meeting, current_user: user,
                                    id: failed.id, params: { rerun: true })).to be_success
      end.not_to change(MeetingAnalysis, :count)

      failed.reload
      expect(failed.creation_flag).to be(true)
      expect(failed.creation_error).to eq('')
      # The frozen snapshot must survive a rerun — that is the whole point of the branch.
      expect(failed.prompt_snapshot).to eq(snapshot_before)
      expect(Meetings::AnalysisJob).to have_received(:perform_later).with(analysis_id: failed.id)
    end

    # Contiguous block, not a single line: a rerun must neither re-embed NOR purge. Content
    # is unchanged at this moment (the async run writes it later), so the #231 cost gate has
    # nothing to bill; and the existing fragments must SURVIVE, otherwise re-running an
    # analysis would silently drop it out of search for the duration of the run.
    it 'neither re-embeds nor purges the fragments of a published, search-released analysis' do
      indexed = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                      include_in_search: true, content: 'Alter Text')
      frag_for(indexed)

      described_class.call(meeting: meeting, current_user: user, id: indexed.id, params: { rerun: true })

      expect(indexed.reload.fragments.count).to eq(1)
      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    # The rerun branch shares load_analysis! with the flip branch, so the 1A meeting scoping
    # must hold here too — a foreign id is a clean failure, never a raise-through.
    it 'fails for an analysis that does not belong to this meeting (1A scoping)' do
      other_meeting = create(:meeting, project: project, organisation: organisation, creator: user)
      foreign = create(:meeting_analysis, meeting: other_meeting, creator: user)

      result = described_class.call(meeting: meeting, current_user: user,
                                    id: foreign.id, params: { rerun: true })

      expect(result.success).to be(false)
      expect(Meetings::AnalysisJob).not_to have_received(:perform_later)
    end
  end

  describe 'flip (publish/unpublish)' do
    let(:analysis) { create(:meeting_analysis, meeting: meeting, creator: user, is_private: true) }

    it 'publishes a private analysis (visible_to_user nulled)' do
      result = described_class.call(meeting: meeting, current_user: user,
                                    id: analysis.id, params: { is_private: 'false' })

      expect(result.success).to be(true)
      analysis.reload
      expect(analysis).not_to be_is_private
      expect(analysis.visible_to_user_id).to be_nil
      expect(Meetings::AnalysisJob).not_to have_received(:perform_later)
    end

    it 'unpublishes a public analysis (visible_to_user restored to creator)' do
      published = create(:meeting_analysis, :published, meeting: meeting, creator: user)

      described_class.call(meeting: meeting, current_user: user,
                           id: published.id, params: { is_private: 'true' })

      published.reload
      expect(published).to be_is_private
      expect(published.visible_to_user_id).to eq(user.id)
    end

    it 'fails for an analysis that does not belong to this meeting (1A scoping)' do
      other_meeting = create(:meeting, project: project, organisation: organisation, creator: user)
      foreign = create(:meeting_analysis, meeting: other_meeting, creator: user, is_private: true)

      result = described_class.call(meeting: meeting, current_user: user,
                                    id: foreign.id, params: { is_private: 'false' })

      expect(result.success).to be(false)
    end
  end

  # Slice 7b: search/chat embedding wiring hangs off the flip. create_embeddings? =
  # !is_private && include_in_search, so the enqueue fires only for a published AND
  # search-released analysis, and only on a real change (#231 cost gate). De-index
  # purges fragments synchronously (decision 5); unpublish clears the search
  # release (4A).
  # Review of #363, finding 1: the 4A bolt reads the persisted visibility from the loaded
  # record. Without a row lock a second transaction can flip it to private between SELECT
  # and UPDATE, and this run then writes its release onto a private analysis.
  describe 'the flip takes the row lock' do
    # ⚠️ This cell pins the MECHANISM, not the behaviour, and that is not an oversight.
    # The behaviour needs TWO connections, and the transactional test setup does not provide
    # them. A wrapper around load_analysis! cannot show it either: an update_all from the
    # SAME transaction passes its own lock, so the cell would be the same with and without
    # the fix. What is proven here: the read takes the lock. NOT proven: that it holds off a
    # competing write.
    it 'loads the analysis FOR UPDATE' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: user,
                                           is_private: true, visible_to_user: user)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        statements << payload[:sql]
      end

      described_class.call(meeting: meeting, id: analysis.id, current_user: user,
                           params: { is_private: 'false' })

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(statements).to include(a_string_matching(/SELECT.+meeting_analyses.+FOR UPDATE/m))
    end
  end

  # Review of #363, finding 2: the F2 nil skip applied only to is_private. A blank
  # include_in_search was passed through as nil, hit the NOT NULL column on a published
  # analysis, and the raw PG message ended up as a flash for the user.
  describe 'a blank include_in_search' do
    ['', nil].each do |blank|
      it "is ignored rather than written (#{blank.inspect})" do
        analysis = create(:meeting_analysis, meeting: meeting, creator: user,
                                             is_private: false, include_in_search: true)

        result = described_class.call(meeting: meeting, id: analysis.id, current_user: user,
                                      params: { include_in_search: blank })

        expect(result).to be_success
        expect(analysis.reload.include_in_search).to be(true)
      end
    end
  end

  describe 'search/chat embedding wiring (Slice 7b)' do
    it 'enqueues the embedding job when a published analysis is released to search' do
      published = create(:meeting_analysis, :published, meeting: meeting, creator: user, content: 'Analyse-Text')

      result = described_class.call(meeting: meeting, current_user: user,
                                    id: published.id, params: { include_in_search: 'true' })

      expect(result.success).to be(true)
      expect(published.reload.include_in_search).to be(true)
      expect(EmbeddingProcessingJob).to have_received(:perform_later).with(
        record_class: MeetingAnalysis, record_id: published.id, fragment_association: :fragments
      )
    end

    it 'does NOT enqueue for a publish flip alone (published but not search-released)' do
      private_one = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true, content: 'x')

      described_class.call(meeting: meeting, current_user: user,
                           id: private_one.id, params: { is_private: 'false' })

      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    it 'does NOT re-enqueue on a no-op re-save of an already-released analysis (#231 cost gate)' do
      indexed = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                      include_in_search: true, content: 'x')

      described_class.call(meeting: meeting, current_user: user,
                           id: indexed.id, params: { include_in_search: 'true' })

      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    # DER Kern (Entscheidung 5): a published+indexed analysis pulled back to private must
    # lose its fragments SYNCHRONOUSLY (no retrievable PII), status reset for a re-index.
    it 'purges fragments synchronously when an indexed analysis is unpublished (Entscheidung 5)' do
      indexed = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                      include_in_search: true, content: 'x', embeddings_creation_flag: true)
      frag_for(indexed)
      expect(indexed.fragments.count).to eq(1)

      described_class.call(meeting: meeting, current_user: user, id: indexed.id, params: { is_private: 'true' })

      indexed.reload
      expect(indexed.fragments.count).to eq(0)
      expect(indexed.embeddings_creation_flag).to be_nil
      expect(indexed.embedding_creation_error).to be_nil
    end

    # Matrix row 4 (embedding v2 PR 2): the opt-out purge must take the fragments'
    # sidecar rows too, synchronously in the actor transaction (PII, no orphan).
    it 'also purges the fragments\' sidecar content_embeddings rows on unpublish' do
      indexed = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                      include_in_search: true, content: 'x')
      fragment = frag_for(indexed)
      create(:content_embedding, organisation: organisation, embeddable: fragment)

      described_class.call(meeting: meeting, current_user: user, id: indexed.id, params: { is_private: 'true' })

      expect(indexed.reload.fragments).to be_empty
      expect(ContentEmbedding.where(embeddable: fragment)).to be_empty
    end

    # Also purge on a pure search-OFF toggle (still published), same fail-closed rule.
    it 'purges fragments synchronously when search is toggled OFF on a published analysis' do
      indexed = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                      include_in_search: true, content: 'x')
      frag_for(indexed)

      described_class.call(meeting: meeting, current_user: user, id: indexed.id, params: { include_in_search: 'false' })

      indexed.reload
      expect(indexed.fragments.count).to eq(0)
      expect(indexed).not_to be_is_private # search off must NOT unpublish (param-safe flip)
    end

    # 4A: unpublishing clears include_in_search — re-publishing does NOT auto-index and
    # does NOT auto-enqueue an embedding (indexing is a deliberate act).
    it 'clears include_in_search on unpublish (4A) and does not re-index on re-publish' do
      indexed = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                      include_in_search: true, content: 'x')

      described_class.call(meeting: meeting, current_user: user, id: indexed.id, params: { is_private: 'true' })
      expect(indexed.reload.include_in_search).to be(false)

      described_class.call(meeting: meeting, current_user: user, id: indexed.id, params: { is_private: 'false' })
      indexed.reload
      expect(indexed.include_in_search).to be(false)
      expect(indexed).not_to be_is_private
      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    # S1 hardening (Eng-Review PR #266): the 4A invariant is enforced in the write seam, not
    # only when THIS flip sets is_private. A crafted search-only PATCH on an already-private
    # analysis (is_private absent from params) must NOT store private + searchable. Not a
    # leak on its own — every retrieval/embed gate is fail-closed on is_private — but it
    # keeps the data honest for any future consumer that reads only include_in_search.
    it 'never stores private + include_in_search on a crafted search-only flip of a private analysis' do
      private_one = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true,
                                              include_in_search: false, content: 'x')

      described_class.call(meeting: meeting, current_user: user,
                           id: private_one.id, params: { include_in_search: 'true' })

      private_one.reload
      expect(private_one).to be_is_private
      expect(private_one.include_in_search).to be(false)
      expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
    end

    # Positive counter-test to the one above (Eng-Review F3): the 4A guard must fetch
    # is_private from the CAST attrs, never from the raw params — "false" is truthy in Ruby,
    # so a @params.fetch would neutralise this legitimate publish+release in one PATCH and
    # nothing else in the suite would go red.
    it 'still releases when the same flip publishes and search-releases together' do
      private_one = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true,
                                              include_in_search: false, content: 'x')

      result = described_class.call(meeting: meeting, current_user: user, id: private_one.id,
                                    params: { is_private: 'false', include_in_search: 'true' })

      expect(result).to be_success
      private_one.reload
      expect(private_one).not_to be_is_private
      expect(private_one.include_in_search).to be(true)
    end

    # Eng-Review F2: a present-but-uncastable is_private ("" → Boolean#cast returns nil) must
    # not occupy the key — otherwise it hits the NOT NULL column (raw PG error as a flash in
    # production) and shadows the persisted value, so the 4A guard would read nil.
    it 'ignores a blank is_private instead of writing nil, and still enforces 4A' do
      private_one = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true,
                                              include_in_search: false, content: 'x')

      result = described_class.call(meeting: meeting, current_user: user, id: private_one.id,
                                    params: { is_private: '', include_in_search: 'true' })

      expect(result).to be_success
      private_one.reload
      expect(private_one).to be_is_private
      expect(private_one.include_in_search).to be(false)
    end

    # The OTHER half of the purge condition (create_embeddings? && plain_text_version.present?).
    # Every existing purge test exercises the opt-in half; this one covers "search-released but
    # there is nothing to index" — released while the run was still pending, or a run that wrote
    # nothing. The fragments must go anyway, otherwise a stale fragment of an emptied analysis
    # stays retrievable. Kills dropping the `.present?` half of the guard.
    it 'purges fragments when a search-released analysis has no content left to index' do
      empty = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                    include_in_search: true, content: '')
      frag_for(empty)

      described_class.call(meeting: meeting, current_user: user,
                           id: empty.id, params: { include_in_search: 'true' })

      expect(empty.reload.fragments.count).to eq(0)
    end

    # The flip params arrive as STRINGS from button_to hidden fields, while the controller's
    # rerun path hands the actor a real Boolean — so the cast surface is wider than
    # "true"/"false". BOTH directions are iterated because they kill DIFFERENT mutations, and
    # neither alone is enough:
    #   * the truthy set dies on boolean() → `value == 'true'` ('1'/'on' would become published)
    #   * the falsy set dies on boolean() → `value.present?` — the classic Ruby trap, where
    #     the STRINGS '0', 'false' and 'off' are all truthy and every publish becomes a
    #     private-ing. The truthy set cannot see that mutation at all.
    #   * the falsy set ALSO dies on `unless is_private.nil?` → `.blank?`, because false.blank?
    #     is true and the publish would be silently dropped.
    # A real Boolean `false` is deliberately NOT in the list: boolean() casts 'false' to the
    # FalseClass instance, so after the cast the string and the real Boolean are the same
    # object — adding it would exercise an indistinguishable path (and test ActiveModel, not
    # us). The real-Boolean route into the actor is params[:rerun], covered in 'rerun'.
    %w[false 0 off].each do |falsy|
      it "casts is_private #{falsy.inspect} to published" do
        private_one = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true)

        described_class.call(meeting: meeting, current_user: user,
                             id: private_one.id, params: { is_private: falsy })

        expect(private_one.reload).not_to be_is_private
      end
    end

    ['true', '1', 'on', true].each do |truthy|
      it "casts is_private #{truthy.inspect} to private and clears the search release (4A)" do
        published = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                          include_in_search: true, content: 'x')

        described_class.call(meeting: meeting, current_user: user,
                             id: published.id, params: { is_private: truthy })

        published.reload
        expect(published).to be_is_private
        expect(published.include_in_search).to be(false)
      end
    end
  end

  # Pins a DELIBERATE non-decision. Neither the model nor the DB forbids
  # private + include_in_search — only this actor does. The fail-closed specs elsewhere
  # (pending_embeddings_spec, combined_search_service_privacy_spec, retriever_content_spec)
  # CONSTRUCT that state on purpose to prove nothing leaks out of it, so adding a model
  # validation or a CHECK constraint would break them at a distance, in another file, with no
  # obvious connection. If THIS test ever goes red, someone added such a constraint: read the
  # reasoning in Actors::SaveMeetingAnalysis#flip_attributes before "fixing" it.
  describe '4A is a write-seam rule, not a data constraint (deliberate)' do
    it 'lets the model persist private + search-released when the actor is bypassed' do
      analysis = create(:meeting_analysis, meeting: meeting, creator: user,
                                           is_private: true, include_in_search: true)

      analysis.reload
      expect(analysis).to be_is_private
      expect(analysis.include_in_search).to be(true)
      # …and even in that state it is never embeddable — the conjunction is the safety net.
      expect(analysis.create_embeddings?).to be(false)
    end
  end
end

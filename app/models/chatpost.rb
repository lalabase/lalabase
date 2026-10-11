# frozen_string_literal: true

# == Schema Information
#
# Table name: chatposts
#
#  id               :uuid             not null, primary key
#  content          :text
#  model_used       :string
#  role             :enum             default("user"), not null
#  source_citations :jsonb            not null
#  source_coverage  :jsonb
#  token_usage      :jsonb            not null
#  tool_calls       :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  chat_id          :uuid             not null
#  organisation_id  :uuid             not null
#  user_id          :uuid
#
# Indexes
#
#  index_chatposts_on_chat_id          (chat_id)
#  index_chatposts_on_organisation_id  (organisation_id)
#
class Chatpost < ApplicationRecord
  include ActionView::RecordIdentifier
  acts_as_tenant(:organisation)
  belongs_to :user, optional: true
  belongs_to :chat
  # The FK nullifies on deletion, without loading a run for every cascaded post.
  has_one :meeting_ticket_suggestion_run, dependent: nil
  attr_accessor :ticket_suggestion_meeting_id

  # The column is a PostgreSQL enum (chatpost_role) and was previously compared as a raw string
  # everywhere. Declaring it here makes the model the owner of the persisted vocabulary and yields
  # the predicates (#assistant?) and scopes (.assistant, .not_assistant) used below.
  #
  # NOT the same vocabulary as the LLM wire roles: providers speak their own dialects (Vertex says
  # "model" for an assistant turn, Anthropic carries the system prompt as a top-level parameter
  # rather than a role). Translation happens at the provider boundary and in
  # ChatResponseJob#build_messages — do not reuse these values there.
  enum :role, { system: 'system', user: 'user', assistant: 'assistant' }

  validate :valid_textile_syntax
  # User input must not be empty/whitespace. DELIBERATELY scoped to role=='user':
  # the assistant post is created with empty content and only filled during
  # streaming — a global presence validation would break that.
  validates :content, presence: true, if: :user_content?
  before_save :set_initial_role

  # Set by ChatResponseJob to the question's author (last_user_post.user) for the
  # duration of an answer. Combined with a content-bearing answer it switches on the
  # gated streaming split (a1, Plan §6) — see gated_streaming?. Not persisted.
  attr_accessor :streaming_asker

  after_create_commit -> { broadcast_created }
  after_update_commit -> { broadcast_updated }

  # Gated streaming (a1): when the answer draws on project content AND the job told us
  # who the asker is, the live token stream goes ONLY to the asker (rendered with the
  # asker as viewer → the render-gate does not redact it, because the retrieval was
  # asker-gated). Everyone else holds the shared-stream placeholder until the answer
  # completes, then gets ONE Turbo page-refresh so they re-render it over the authorised
  # HTTP path (render-gate → text or placeholder per their own rights). Code-only /
  # context-free answers (no citation area) keep the plain shared-stream broadcast.
  #
  # Note on the gated path: the asker is subscribed to BOTH streams (shared + own) and the
  # placeholder is appended to both. That is NOT a double bubble — both appends target the
  # same dom_id container, so Turbo replaces the element by id rather than appending twice;
  # the asker ends up with exactly one bubble, then receives the deltas on its own stream.
  def broadcast_created
    return if analysis_context.to_h['ticket_suggestion_run_id'].present?

    if gated_streaming?
      broadcast_append_to(asker_stream, target: chat.chatposts_dom_id,
                                        renderable: build_message_component(viewer: streaming_asker))
    end
    broadcast_append_to(chat.chatposts_dom_id, target: chat.chatposts_dom_id,
                                               renderable: build_message_component)
  rescue StandardError => e
    Rails.logger.error "Chatpost broadcast created error: #{e.message}"
  end

  def broadcast_updated
    return if analysis_context.to_h['ticket_suggestion_run_id'].present?

    if gated_streaming?
      broadcast_replace_to(asker_stream, target: dom_id(self).to_s,
                                         renderable: build_message_component(viewer: streaming_asker))
    else
      broadcast_replace_to(chat.chatposts_dom_id, target: dom_id(self).to_s,
                                                  renderable: build_message_component)
    end
    # Only once the answer is complete (model_used set by the folded final write).
    broadcast_completed if model_used.present?
  rescue StandardError => e
    Rails.logger.error "Chatpost broadcast updated error: #{e.message}"
  end

  # What has to happen when an answer finishes, in two shapes because the two
  # surfaces sit on different pages.
  #
  # The refresh does two jobs at once: viewers who held the placeholder re-render
  # over the authorised HTTP path, and the PREVIOUS answer loses its regenerate
  # pill (pills render only on the newest assistant answer).
  #
  # projekt_chat_abbau: there is only the ORG shape left. The other half of this
  # branch belonged to the surface projekt_chat_abbau removed, watched from a PAGE that
  # opted into `turbo-refresh-method: morph`, making a refresh cheap. No such page
  # exists any more, so the refresh is gone with it and the branch is not.
  #
  # ORG threads (S3a T4) must NOT refresh. Their subscriber is the companion
  # panel, and the panel rides on whatever page the user is looking at — a ticket
  # list, a meeting, a note. None of those carry the morph meta, so a refresh
  # there degrades into a full replace visit and takes the open detail with it
  # ("the answer arrives and your ticket closes"). The first job also cannot
  # arise: since S1 an org thread has exactly one reader, so nobody is holding a
  # placeholder. What is left is the stale pill, and that is one targeted replace.
  # ⚠️ The replace below runs INSIDE the job, where Current.user is nil, and
  # MessageComponent#redacted? blacks out every content-bearing answer for a nil
  # viewer BEFORE it reaches the owner short-circuit. The refresh this replaced
  # never had that problem: it re-rendered over the authorised HTTP path. So this
  # branch names its viewer and, exactly like the a1 split above, puts the
  # un-redacted render on the OWNER'S OWN stream, which Turbo signs per user --
  # never on the shared one. An org thread has exactly one legitimate reader
  # (ChatPolicy: owner only, no admin bypass), and that is who this is for.
  def broadcast_completed
    owner = chat.user
    return if owner.nil?

    # chat.chatposts is ordered created_at ASC by the association, so #last is
    # the newest answer BEFORE this one.
    previous = chat.chatposts.assistant.where.not(id: id).last
    return if previous.nil?

    broadcast_replace_to(
      [chat, owner],
      target: dom_id(previous).to_s,
      # organisation from the CHAT, not from Current: the job sets the tenant but
      # not Current.organisation, and MessageComponent#show_delete? requires both
      # a user and an organisation -- so the re-rendered previous answer silently
      # lost its delete affordance until the next full load.
      renderable: build_message_component(viewer: owner, organisation: chat.organisation, chatpost: previous)
    )
  end

  # Per-asker stream for the live token deltas. Each viewer subscribes only to its OWN
  # [chat, current_user] stream (Turbo signs the stream name), so only the asker receives
  # these — never another reader.
  def asker_stream
    [chat, streaming_asker]
  end

  def gated_streaming?
    streaming_asker.present? && content_bearing?
  end

  # The answer drew on project content (a citation carrying an `area`), as opposed to a
  # code-only / context-free answer. source_citations is set from the start (the job
  # seeds the placeholder with the retriever's citations), so this is stable across the
  # delta writes.
  #
  # Delegates the area derivation to Lalabase::Citations.areas_of — the SAME source the
  # render-gate (MessageComponent#sourced_areas) consults — so the gated-streaming trigger
  # and the redaction decision can never drift apart (a1's correctness property). See the
  # header on areas_of for why a single derivation matters.
  def content_bearing?
    Lalabase::Citations.areas_of(source_citations).any?
  end

  # Pull request-local org from CurrentAttributes so the live-streamed bubble has the same
  # authorization context as the initial render. viewer defaults to Current.user (nil in
  # the job → content answers redact fail-closed on the shared stream, as before); the
  # gated asker stream passes the asker explicitly so it renders un-redacted for them.
  # `chatpost:` defaults to self; broadcast_completed passes a SIBLING post (the
  # previous answer, re-rendered so its regenerate pill disappears) rather than
  # building a second component by hand somewhere else.
  def build_message_component(viewer: Current.user, organisation: Current.organisation, chatpost: self)
    Neo::Chat::MessageComponent.new(
      chatpost: chatpost,
      current_user: viewer,
      current_organisation: organisation,
      show_delete: viewer.present?,
      # From the post being RENDERED, not from self: broadcast_completed renders a
      # SIBLING post, and handing it this post's resolver would ask about citations
      # it was never built for (answer: nothing, so its links would simply stop
      # being checked -- silent, and exactly the wiring mistake the resolver's
      # evidence rule is meant to make harmless rather than invisible).
      citation_targets: chatpost.citation_targets
    )
  end

  # ONE existence resolver per answer, memoised on the RECORD rather than on the
  # component. The streaming broadcast is not "a single bubble once": ChatResponseJob
  # writes one update! per token delta (chat_response_job.rb, the runner block), and
  # after_update_commit re-renders this whole bubble each time. A resolver built per
  # render therefore cost one query per cited type per TOKEN -- on the path the job
  # folds three writes into one to keep cheap, and for a list that was DB-free before.
  #
  # Keyed on the citations themselves because the job folds the runner's citations in
  # once after the placeholder was created, so the first render's answer must not be
  # kept once the sources are known.
  def citation_targets
    citations = source_citations
    unless defined?(@citation_targets_for) && @citation_targets_for == citations
      @citation_targets_for = citations
      @citation_targets = Lalabase::CitationTargets.for(citations: citations, organisation: organisation)
    end
    @citation_targets
  end

  # Protects against directly deleting a system message when the chat still has other
  # posts. `destroyed_by_association` is set when Rails destroys this instance as part
  # of a parent cascade (Chat#destroy → dependent: :destroy) — in that case the guard
  # must NOT apply, otherwise the chat is left behind with orphans.
  def destroy
    # On a parent cascade (Chat#destroy → dependent: :destroy), destroyed_by_association
    # is set. Then the guard must not apply and is_destroyable? is not even called —
    # otherwise N+1 queries arise and the guard blocks legitimate cascades.
    return super if destroyed_by_association

    unless is_destroyable?
      errors.add(:base, :system_cannot_delete)
      return false
    end
    super
  end

  # The second clause of the old form (`role == 'system' && …`) was redundant: it could only be
  # reached when the first clause was already false, i.e. when the post IS the system post.
  def is_destroyable?
    !system? || chat.chatposts.count == 1
  end

  def is_first?
    id == chat.chatposts.first.id
  end

  # The key binds the form to exactly the displayed answer, including regeneration.
  def analysis_answer_key
    Digest::SHA256.hexdigest(canonical_analysis_value([id, content, source_citations, source_coverage, analysis_context]).to_json)
  end

  def savable_meeting_answer?
    assistant? && model_used.present? && content.present? &&
      analysis_context.is_a?(Hash) && analysis_context['meeting_ids'].present? &&
      analysis_context['instructions'].present?
  end

  private

  # JSONB reorders object keys on reload; a broadcast and the later HTTP read must
  # produce the same key. Array order (source numbering) remains significant.
  def canonical_analysis_value(value)
    case value
    when Hash then value.sort.to_h.transform_values { |item| canonical_analysis_value(item) }
    when Array then value.map { |item| canonical_analysis_value(item) }
    else value
    end
  end

  def user_content?
    user?
  end

  def valid_textile_syntax
    RedCloth.new(content).to_html
  rescue StandardError => e
    errors.add(:content, :textile_syntax_error, error: e.message)
  end

  def set_initial_role
    self.role = :system if chat.chatposts&.none?(&:system?)
  end
end

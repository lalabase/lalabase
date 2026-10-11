# frozen_string_literal: true

module Neo
  module Chat
    # Renders a single chatpost (bubble). Consolidates the previous _chatpost.html.erb
    # and _chatpost_content.html.erb partials. `show_delete:` is the caller's
    # chats:write verdict — computed ONCE by ChatContainerComponent, not re-derived
    # per bubble (avoids a policy lookup per message). Combined with the post being
    # destroyable, not the first message, and a present user/org, it decides whether
    # the delete icon shows. Server-side authorization in
    # AssistantChatpostsController#destroy
    # remains the real gate.
    class MessageComponent < ViewComponent::Base
      include ActionView::Helpers::DateHelper

      # LLM answers (and human replies) are Markdown. The renderer + allowlist now
      # live in Lalabase::SafeMarkdown (shared with the meeting detail — was a copy
      # per render site). Re-exposed here as this component's contract so existing
      # specs and any reader still see WHAT it renders.
      ALLOWED_TAGS = Lalabase::SafeMarkdown::ALLOWED_TAGS
      ALLOWED_ATTRIBUTES = Lalabase::SafeMarkdown::ALLOWED_ATTRIBUTES

      def initialize(chatpost:, current_user: nil, current_organisation: nil, show_delete: false,
                     area_access_cache: nil, last_assistant_id: :derive, citation_targets: nil, analysis_eligibility: nil)
        @chatpost = chatpost
        @current_user = current_user
        @current_organisation = current_organisation
        @show_delete = show_delete
        # Id of the chat's newest assistant post — pills render only there.
        # ChatContainerComponent passes it in (computed once for the whole list);
        # :derive = look it up here (the single-bubble broadcast path).
        @last_assistant_id = last_assistant_id
        # Shared per-(viewer, chat) cache for the render-gate's area_access? verdicts.
        # ChatContainerComponent passes ONE cache down to every bubble so the policy is
        # hit once per area across the whole chat (R3, #6), not once per bubble. nil → own
        # cache, which is fine in the broadcast (a single bubble, current_user nil anyway).
        @area_access_cache = area_access_cache || {}
        # Shared existence resolver for the source links (Feinschliff B). Like the
        # cache above it is built ONCE per transcript by ChatContainerComponent, so a
        # long conversation costs one query per target type instead of one per answer.
        # nil → this bubble resolves its own, which is the streaming broadcast path.
        @citation_targets = citation_targets
        @analysis_eligibility = analysis_eligibility
      end

      # Strip the source-attribution marker BEFORE rendering (§6.3): it lands at the
      # very end of the token stream, so a mid-stream delta briefly carries the marker
      # (or a partial prefix of it), and a job that crashed after streaming but before
      # the persist-strip would leave it in `content`. SourceAttribution.strip is inert
      # on a marker-free answer, so this changes nothing until the mechanism is live.
      def sanitized_content
        html = Lalabase::SafeMarkdown.render(Lalabase::ProjectRag::SourceAttribution.strip(@chatpost.content))
        # NOT while the answer is still arriving: this render runs once per token on
        # the streaming path, and weaving the links means a second Nokogiri parse of
        # the whole answer so far — quadratic in its length, measured at about five
        # times the markdown cost (review of #624). The reader keeps the LAST render,
        # and the folded final write carries model_used, so the finished answer is
        # linked. Same predicate the regenerate affordance stands on, so "finished"
        # cannot mean two things here.
        return html if answer_pending?

        Lalabase::CitationInlineLinks.apply(html: html, citations: linkable_citations,
                                            organisation: @chatpost.organisation,
                                            numbering: source_numbering)
      end

      # What the PROSE may link (Feinschliff C). Both filters already exist and the
      # prose widens neither: visible_citations is the viewer's render gate, and a
      # target that is gone loses its link in the source list for the same reason it
      # must not gain one in the sentence above it.
      def linkable_citations
        visible_citations.reject { |citation| citation_targets.gone?(citation) }
      end

      # Minimal layout: with the avatar column gone, the roles are told apart by
      # surface — a human question gets a subtly tinted bubble, an assistant answer
      # stays plain prose (document feel). Gate on "not assistant", NOT on role
      # 'user': set_initial_role coerces the first post of every chat to 'system'
      # although it is the human's opening question.
      #
      # rounded-2xl is the composer field's radius (#633): the thing you type into
      # and the thing it becomes should not be two different shapes.
      def content_classes
        base = 'prose prose-sm max-w-none dark:prose-invert break-words'
        return base if @chatpost.assistant?

        "#{base} px-3.5 py-2 bg-surface-shell rounded-2xl"
      end

      # The row the message sits in. A question is pushed to the right edge, an
      # answer keeps the full column (2026-08-28 feedback).
      #
      # ⚠️ The four-fifths cap is a left INSET (ps-[20%]), not a max-width. The
      # bubble carries the typography plugin's `prose`, whose own max-width the
      # component neutralises with `max-w-none`; a second max-width utility on the
      # same element would have to out-rank that one, and which of two equally
      # specific utilities wins is decided by the order Tailwind happens to emit
      # them in. Reserving the left fifth of the row caps the flex item just as
      # well and cannot lose that race.
      def content_row_classes
        return 'mt-1.5' if @chatpost.assistant?

        'mt-1.5 flex justify-end ps-[20%]'
      end

      def dom_id
        ActionView::RecordIdentifier.dom_id(@chatpost)
      end

      def time_ago
        return nil unless @chatpost.created_at

        t('views.organisations.chats.message.time_ago', time: time_ago_in_words(@chatpost.created_at))
      end

      # Is there anything to put in the hover row at all? Asked so a message with
      # neither a time nor an action does not reserve an empty band above itself.
      # In practice every persisted post has a time, so this is the empty-state
      # answer, not the common one.
      def show_meta_row?
        time_ago.present? || show_regenerate? || show_copy? || show_delete?
      end

      # Copy this message's text (2026-08-28 feedback: asking the same question
      # again should not mean re-typing it). Offered on both roles — the trash
      # next to it is, and copying an answer into a ticket is the same move.
      #
      # NOT on a redacted answer, for the reason regenerate is not offered there
      # either: the viewer may not read that text, so they must not be handed a
      # copy of it. Blank content means there is nothing to copy yet (the
      # placeholder bubble before the first token arrives).
      def show_copy?
        return false if redacted?

        @chatpost.content.present?
      end

      def show_delete?
        return false unless @show_delete
        return false if @chatpost.id.blank?
        return false unless @chatpost.respond_to?(:is_destroyable?) && @chatpost.is_destroyable?
        return false if @chatpost.respond_to?(:is_first?) && @chatpost.is_first?
        return false unless @current_user && @current_organisation

        true
      end

      # IDs, not records: the route only needs the segments, and dereferencing
      # @chatpost.organisation here made the render depend on an association load
      # that came back nil intermittently under the system-test server -- a 500 for
      # the whole panel, triggered by nothing more than a thread with a deletable
      # message. Nothing about this path needs the object.
      def delete_path
        helpers.organisation_assistant_chat_chatpost_path(
          @chatpost.organisation_id, @chatpost.chat_id, @chatpost.id
        )
      end

      # Per-answer "regenerate" action. Shown only on a COMPLETED
      # assistant answer: while streaming (and during a regenerate) model_used is
      # nil, so the link is absent — which is also why a second click can't fire
      # mid-stream. Deliberately NOT gated on the viewer's write permission here:
      # the answer-complete render happens inside the streaming job's broadcast,
      # where Current.user/organisation are nil and the stream is viewer-agnostic
      # (same reason show_delete? degrades there). The real gate is the server-side
      # authorize(:update?) in AssistantChatpostsController#regenerate.
      #
      # Shown ONLY on the LAST completed assistant answer (2026-07-18 feedback —
      # was: every answer, which cluttered the log). Older answers lose the action
      # through the completion page-refresh (broadcast_refresh_to fires on
      # every completed answer; morph re-renders the whole list). Consequence:
      # mid-history regenerate is no longer offered — regenerating an older
      # answer only used the history before it anyway, which confused more than
      # it helped.
      #
      # 2026-07-19: this replaced four style pills (kürzer/ausführlicher/…) that
      # each regenerated AND silently shifted the stored style level. Style is now
      # picked explicitly in the pills under the composer; what remains here is the
      # pure action, which re-runs the answer with whatever level is currently set.
      def show_regenerate?
        # Not on a redacted answer: the viewer can't see the text, so they must not be
        # able to regenerate it either.
        @chatpost.assistant? && @chatpost.content.present? && answer_complete? &&
          !redacted? && last_assistant_answer?
      end

      # The folded final write (ChatResponseJob) sets model_used; until then the
      # bubble is a streaming/placeholder/error row with no answer to regenerate.
      def answer_complete?
        @chatpost.model_used.present?
      end

      # Role and "still waiting" as DATA attributes on the bubble (S3a T4). The
      # companion panel reads them to decide whether it must re-fetch the
      # transcript after a Turbo transplant dropped its cable subscription (see
      # the template comment). Derived from the SAME answer_complete? the
      # regenerate pill uses; terminal error copy also ends the wait, but never
      # enables answer actions.
      def chat_role
        @chatpost.role
      end

      def answer_pending?
        # Explicit empty provenance marks terminal error copy, not a live stream.
        @chatpost.assistant? && !answer_complete? && @chatpost.analysis_context != { 'provenance' => [] }
      end

      # Derived from the chatpost itself (org + chat + project), NOT from
      # @current_organisation — so the path is correct even in the job broadcast
      # where Current/@current_* are nil.
      def regenerate_path
        helpers.regenerate_organisation_assistant_chat_chatpost_path(
          @chatpost.organisation, @chatpost.chat, @chatpost
        )
      end

      # Render-gate (Plan §4.4): the viewer sees the answer text ONLY if they may read
      # EVERY content area the answer drew on. Otherwise the prose is redacted as a whole
      # (all-or-nothing — woven text can't be safely partially blacked out) and
      # foreign-area citations are hidden (visible_citations). The check runs against THIS
      # viewer at display time, so a member added AFTER the answer was generated is still
      # gated. Fail-closed without a current_user (the streaming-job broadcast renders with
      # Current.user nil): a content-bearing answer is redacted there; the authorised HTTP
      # render (current_user present) is what shows it. Code-only answers (citations
      # without an area) are ungated — code context is visible to every chat reader anyway.
      def redacted?
        return false if sourced_areas.empty?
        return true if @current_user.nil?
        # Owner short-circuit (S3a, R-H2): the policy guarantees owner == only asker
        # since creation, so every answer was retrieved under the owner's own rights.
        # Without it the area gate below would black out an answer for the very person
        # it was generated for. Non-owners and the viewer-agnostic broadcast
        # (current_user nil, above) stay fail-closed.
        #
        # This used to be narrowed to ORG-WIDE threads because project threads had a
        # second, weaker case (retrieval gated per QUESTION, legacy pre-S1 answers
        # fetched under a colleague's rights). Since projekt_chat_abbau there is only
        # the one kind, and #org_thread? is trivially true.
        return false if owner_viewer?

        sourced_areas.any? { |area| !area_allowed?(area) }
      end

      def redacted_notice
        t('views.organisations.chats.message.redacted')
      end

      # L7 (S3a T3): the narrowing notice under an org-wide answer, rendered
      # DETERMINISTICALLY from the persisted contract field
      # (chatposts.source_coverage) — never from the model's prose. Silent when
      # nothing was narrowed, when no coverage applies (single-project answers),
      # and under a redacted answer: L7 labels an answer the viewer may read.
      def coverage_notice
        return nil if redacted?

        Assistant::CoverageNotice.call(coverage: @chatpost.source_coverage)
      end

      # Citations the viewer may see. TWO independent filters, in this order:
      #   1. the area gate (SECURITY): code citations (no area) always; content
      #      citations only for areas the viewer may read — otherwise the citation's
      #      title/number would leak the very content the redaction hides.
      #   2. the used-flag (ATTRIBUTION, §7): drop a citation the model did not use
      #      (`used: false`). Legacy hashes carry no flag → `c['used']` is nil →
      #      `!= false` → still shown, so pre-attribution answers keep all sources.
      # The gate stays the OUTER, untouched filter; the used-flag never widens access.
      def visible_citations
        @chatpost.source_citations.select do |c|
          next false unless c.is_a?(Hash)

          area = c['area']
          # Owner short-circuit mirrors redacted? (R-H2): whoever may read the
          # prose may see its sources. The used-flag still applies.
          area_allowed = owner_viewer? || area.nil? || (!@current_user.nil? && area_allowed?(area.to_sym))
          area_allowed && c['used'] != false
        end
      end

      # Resolved over the FULL citation list, not visible_citations: the gate decides
      # what is rendered, this decides whether what is rendered may link, and asking
      # about a citation the resolver never looked for is deliberately unanswerable.
      def citation_targets
        @citation_targets ||= Lalabase::CitationTargets.for(
          citations: @chatpost.source_citations, organisation: @chatpost.organisation
        )
      end

      # The [n] numbering over the FULL persisted list (R2/R3), like citation_targets
      # above and for the same shape of reason: number n = source_citations[n-1] is
      # what the prompt showed the model (SourceNumbering, shared with
      # apply_used_flags), so it must not shift when the visible subset differs per
      # viewer. The prose resolver and the numbered source list both read THIS one,
      # so a "[3]" in the text and the row labelled [3] can never disagree.
      def source_numbering
        @source_numbering ||= Lalabase::ProjectRag::SourceNumbering.for(@chatpost.source_citations)
      end

      private

      # True when this bubble belongs to an org-wide thread (no project). Routes
      # and the render gate branch on this; works in the broadcast.
      def org_thread?
        @chatpost.chat&.org_thread?
      end

      # The viewer owns this ORG-WIDE thread (R-H2). Asks the model's ONE
      # predicate (#org_thread?) plus the id match -- deliberately NOT bare
      # #personal?: a user_id alone does not make a thread single-asker (legacy
      # multi-author project threads), and the gate must not open on those. nil current_user is never
      # an owner, so the broadcast path stays fail-closed.
      def owner_viewer?
        @current_user.present? && @chatpost.chat&.org_thread? &&
          @chatpost.chat.user_id == @current_user.id
      end

      def last_assistant_answer?
        return false if @chatpost.id.blank?

        id = @last_assistant_id == :derive ? derive_last_assistant_id : @last_assistant_id
        id == @chatpost.id
      end

      # Broadcast path only (container passes the id in): one indexed lookup per
      # broadcast, not per bubble.
      def derive_last_assistant_id
        @chatpost.chat.chatposts.assistant
                 .order(created_at: :desc, id: :desc).limit(1).pick(:id)
      end

      # Areas the answer's content drew on, derived from its citations (symbolised, R2:
      # JSONB stores the area as a String, area_access? expects a Symbol). Code citations
      # carry no area and so never contribute here. Delegates to Lalabase::Citations.areas_of
      # — the SAME derivation Chatpost#content_bearing? uses for the gated-streaming split —
      # so the render-gate and the streaming trigger can never disagree about which areas an
      # answer touches (a1's correctness property; see areas_of's header).
      def sourced_areas
        @sourced_areas ||= Lalabase::Citations.areas_of(@chatpost.source_citations)
      end

      # Cached so a chat full of gated bubbles hits the policy once per area, not per
      # bubble (R3). false is cached too (key? guard), unlike a naive ||= — denied areas
      # are the common redaction case and must not re-query per bubble.
      # (NeoProjectNavigationComponent deliberately uses the naive ||= and is fine THERE:
      # single render + its `read || write` is truthy whenever access exists, so a false
      # never gets re-queried. Here false is the common, multi-bubble case — hence key?.)
      # projekt_chat_abbau: this used to ask ProjectPolicy about the thread's project.
      # There is no thread with a project any more, and ProjectPolicy already answered
      # false for a nil record (`record&.organisation` in
      # #active_member_of_record_organisation?), so this is what the code has been
      # doing all along for an org thread -- said out loud instead of routed through a
      # policy that cannot answer.
      #
      # NOT deleted with the branch it fed: it is the fail-closed floor under
      # #redacted? for anyone who is not the owner. Today ChatPolicy::Scope means
      # nobody else reaches a bubble at all; the floor is what holds if that ever
      # stops being true.
      def area_allowed?(_area)
        false
      end
    end
  end
end

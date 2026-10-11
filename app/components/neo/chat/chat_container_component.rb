# frozen_string_literal: true

module Neo
  module Chat
    # Top-level chat view: messages list + composer (or read-only notice).
    # Replaces app/views/organisations/chats/_chat_show.html.erb.
    class ChatContainerComponent < ViewComponent::Base
      include Turbo::StreamsHelper
      # FramesHelper for the disabled-state notice, which must render inside
      # the composer's turbo frame (see template comment on the guard path).
      include Turbo::FramesHelper

      # The outer turbo frame's id. "chat-show" is a LITERAL contract: citation
      # links escape it by name (citation_list_component: data-turbo-frame="_top"
      # relative to THIS frame) and the chat pages' CSS knows it. No turbo stream
      # replaces it by name any more (the last one went with S4-T1's ticket chat);
      # it stays the default so every existing caller keeps its behaviour.
      #
      # The companion panel passes its own (S3a T4): it renders this component on
      # top of whatever page the user is on, INCLUDING the chat pages, and two
      # elements with the same id in one document mean turbo_stream.replace hits
      # whichever one comes first in document order. That works today only
      # because the panel is rendered after <main>, which is not a property
      # anyone should have to know.
      DEFAULT_FRAME_ID = 'chat-show'

      # The companion panel's own frame id, named here rather than in the panel
      # partial that passes it: this component now ASKS which surface it is on
      # (see #panel?), so the string has a reader as well as a writer, and a
      # literal in both places is the pair that drifts.
      PANEL_FRAME_ID = 'assistant-panel-chat'

      # projekt_chat_abbau dropped `project:`: the only thing it still fed was the
      # composer's POST target, and that no longer branches on a project.
      def initialize(chat:, current_user:, current_organisation:, frame_id: DEFAULT_FRAME_ID)
        @chat = chat
        @current_user = current_user
        @current_organisation = current_organisation
        @frame_id = frame_id
      end

      attr_reader :frame_id

      # Every thread is org-wide since projekt_chat_abbau, so there is no project
      # area to ask: the write question is ChatPolicy (owner + assistant pair).
      # This used to branch, with the project half asking ChatsHelper#can_write_chats?
      # for the `chats` area; that helper went with the surface.
      def can_write?
        return @can_write if defined?(@can_write)

        # Ternary, not a trailing `if`: that form assigns nothing when @chat is nil, so
        # `defined?(@can_write)` stayed false and the memoisation was dead in exactly
        # the case the guard exists for.
        @can_write = @chat ? helpers.policy(@chat).update? : false
      end

      # R4 (doc/ai_feature_registry_plan.md): the composer asks the FEATURE, not just the
      # GDPR opt-in. :chat is the row that routes ChatResponseJob — the job this
      # composer's submit ends up enqueueing — so the field and the machinery behind it
      # cannot disagree about whether a route exists. One surface, one row, one routing
      # decision.
      #
      # Before R4 an opted-in org with no usable chat credential got a working-looking
      # composer whose messages never came back. It now reads the reason in the
      # composer's place — in the same amber notice the opt-in case has always used,
      # because both states are "you cannot send from here, and this is why".
      #
      # Returns the Availability rather than a boolean: the template needs the reason.
      # A nil organisation stays possible and answers "not available".
      def chat_availability
        return @chat_availability if defined?(@chat_availability)

        @chat_availability = @current_organisation&.ai_available_for?(:chat)
      end

      def chat_available?
        chat_availability&.available? || false
      end

      def chatposts_frame_id
        @chat.chatposts_dom_id
      end

      def chatposts_stream_name
        chatposts_frame_id
      end

      # a1 live stream (Plan §6): each viewer subscribes to its OWN [chat, current_user]
      # stream. The job broadcasts the asker's live token deltas to [chat, asker], so only
      # the asker (whose current_user == asker) receives them — never another reader, since
      # Turbo signs the stream name per (chat, user).
      def viewer_stream
        [@chat, @current_user]
      end

      def composer
        ComposerComponent.new(
          chat: @chat,
          chatpost: Chatpost.new,
          current_organisation: @current_organisation
        )
      end

      # The requesting user's persistent style pills, rendered here (has
      # current_user/org) rather than in the viewer-agnostic chatpost broadcast.
      # Sits UNDER the composer: it configures what comes next, so it belongs
      # with the writing affordance, not in the header above the transcript.
      def style_control
        StyleControlComponent.new(
          current_user: @current_user,
          current_organisation: @current_organisation
        )
      end

      # What the assistant is pointed at (S3a T5 §9.3, S4 T2 §7.3), rendered next
      # to the composer it belongs to: the scope chip and the reference chip, in
      # the wrapper that is their turbo anchor. Each chip decides for itself
      # whether it applies, so this stays one line and the rules live in one
      # place each (see ScopeRowComponent for why the wrapper is not optional).
      def scope_row
        ScopeRowComponent.new(
          chat: @chat,
          current_user: @current_user,
          current_organisation: @current_organisation
        )
      end

      # Which surface this is. Only the companion panel travels with the user
      # from page to page, so only there can a page context be offered (S4 T2
      # step 5b) -- a chat page IS the page you are on.
      def panel?
        frame_id == PANEL_FRAME_ID
      end

      # The context offer strip, above the row that shows the reference it
      # offers to set. Client-filled and hidden until the panel controller has
      # something to say; see ContextOfferComponent for why it lives here and no
      # longer in the panel shell.
      def context_offer
        ContextOfferComponent.new
      end

      def before_render
        ActiveRecord::Associations::Preloader.new(
          records: @chat.chatposts.to_a,
          associations: { meeting_ticket_suggestion_run: [{ meeting: :project }, { meeting_ticket_suggestions: { similar_ticket: :project, created_ticket: :project } }] }
        ).call
      end

      def message_for(chatpost)
        MessageComponent.new(
          chatpost: chatpost,
          current_user: @current_user,
          current_organisation: @current_organisation,
          show_delete: can_write?,
          area_access_cache: area_access_cache,
          last_assistant_id: last_assistant_id,
          citation_targets: citation_targets,
          analysis_eligibility: analysis_eligibilities[chatpost.id]
        )
      end

      def analysis_eligibilities
        @analysis_eligibilities ||= Assistant::AnalysisEligibility.for_answers(
          answers: @chat.chatposts, user: @current_user, organisation: @chat.organisation
        )
      end

      # ONE existence resolver for every source link in the list (Feinschliff B):
      # the transcript is already loaded, so this costs one query per target type
      # for the whole conversation rather than one per answer. Built from the SAME
      # association the template iterates, so it cannot miss a bubble.
      def citation_targets
        @citation_targets ||= Lalabase::CitationTargets.for(
          citations: @chat.chatposts.select(&:assistant?).flat_map { |post| post.source_citations || [] },
          organisation: @chat.organisation
        )
      end

      # Newest assistant post, computed ONCE from the already-loaded association
      # (the template iterates it) and passed to every bubble — pills render only
      # on the last answer, and per-bubble derivation would N+1.
      def last_assistant_id
        return @last_assistant_id if defined?(@last_assistant_id)

        @last_assistant_id = @chat.chatposts.select(&:assistant?).last&.id
      end

      # ONE render-gate area_access? cache shared by every bubble in the list (R3, #6):
      # the policy is hit once per area for this viewer, not once per message.
      def area_access_cache
        @area_access_cache ||= {}
      end
    end
  end
end

# frozen_string_literal: true

module Neo
  module Chat
    # The chat message form (textarea + inline send icon).
    #
    # Two modes, ONE source of truth for the field's look and its Stimulus
    # wiring (see MESSAGE_FIELD_CLASSES / #message_field_options):
    #
    #   :reply    — posts another message into an existing chat. Wrapped in the
    #               composer turbo frame so chatposts#create can replace it.
    #   :new_chat — the first message of a not-yet-created chat, posted to
    #               chats#create together with the persona pick. NO turbo frame:
    #               create redirects, and a frame would swallow the navigation.
    #
    # The modes existed as two hand-maintained copies before (new.html.erb and
    # _new_form.html.erb) and drifted apart the moment the composer was
    # restyled — hence the shared field options rather than duplicated markup.
    class ComposerComponent < ViewComponent::Base
      include Turbo::FramesHelper

      MODES = %i[reply new_chat].freeze

      # ⚠️ The one place the field's look is defined, for BOTH modes and both
      # surfaces (chat page and companion panel). Restyling belongs here, so it
      # can never again land on the reply form only.
      #
      # Softened on 27.08.2026: rounded-2xl and a single hairline instead of the
      # house border-2 black with its offset shadow on focus. Same move the panel
      # edge, its "Neuer Chat" button and the context offer made, and for the same
      # reason -- this field sits in a quiet reading surface, and the heaviest
      # outline on that surface should not be the empty box you have not typed
      # into yet. focus:border-ink keeps the focus visible without moving the
      # field: the translate pair shifted every element below it by two pixels
      # each time the cursor landed.
      MESSAGE_FIELD_CLASSES = 'mt-1 block w-full px-4 py-2.5 pr-12 bg-surface-raised border border-cream-300 ' \
                              'rounded-2xl resize-none overflow-hidden placeholder-gray-400 focus:outline-none ' \
                              'focus:border-ink focus:ring-0 transition-colors'

      # chatpost is the :reply mode's form model. current_user is only consulted in
      # :new_chat mode — the post's author is part of assistant_chats#create's nested
      # params, while a reply gets its author server-side.
      #
      # projekt_chat_abbau dropped three arguments: `project:` (every thread is
      # org-wide, so the POST target no longer branches on one) and the pair
      # `personas:` / `selected_persona_id:`, whose only caller was the project
      # chat's new-conversation form. The persona itself did NOT go: it is a
      # standing choice per person now (PersonaControlComponent), and
      # chats.prompt_persona_id is untouched, so per-conversation personas can come
      # back as a UI slice.
      def initialize(chat:, current_organisation:, chatpost: nil, mode: :reply, current_user: nil)
        raise ArgumentError, "unknown composer mode: #{mode}" unless MODES.include?(mode.to_sym)

        @chat = chat
        @chatpost = chatpost
        @current_organisation = current_organisation
        @mode = mode.to_sym
        @current_user = current_user
      end

      def new_chat?
        @mode == :new_chat
      end

      def frame_id
        @chat.chatpost_form_dom_id
      end

      # :new_chat renders bare; :reply keeps the turbo frame chatposts#create
      # targets. Written as a wrapper so both modes share ONE form body below.
      def composer_wrapper(&block)
        return capture(&block) if new_chat?

        turbo_frame_tag(frame_id, &block)
      end

      def form_options
        base = { data: {
          controller: 'neo-chat-composer meeting-analysis-composer assistant-suggestion-composer',
          assistant_suggestion_composer_url_value: helpers.organisation_assistant_ticket_suggestion_meetings_path(@current_organisation),
          assistant_suggestion_composer_prompt_value: t('assistant_suggestions.prompt'),
          assistant_suggestion_composer_choose_value: t('assistant_suggestions.choose'),
          assistant_suggestion_composer_error_value: t('assistant_suggestions.load_error'),
          assistant_suggestion_composer_unavailable_value: t('assistant_suggestions.unavailable'),
          assistant_suggestion_composer_appended_value: t('assistant_analysis.appended'),
          assistant_suggestion_composer_pending_value: t('assistant_suggestions.pending_reference'),
          action: 'assistant:revise@window->meeting-analysis-composer#revise',
          meeting_analysis_composer_chat_id_value: @chat.id,
          meeting_analysis_composer_url_value: helpers.organisation_assistant_analysis_prompts_path(@current_organisation),
          meeting_analysis_composer_error_value: t('assistant_analysis.error'),
          meeting_analysis_composer_appended_value: t('assistant_analysis.appended'),
          meeting_analysis_composer_empty_value: t('assistant_analysis.no_templates'),
          meeting_analysis_composer_draft_value: new_chat?
        } }
        return base.merge(model: @chatpost, url: form_url) unless new_chat?

        # Explicit scope + url instead of a polymorphic model array: route
        # resolution for nested records is unreliable from inside a component.
        base[:data][:action] = 'submit->assistant-panel#guardDraftSubmit ' \
                              'turbo:submit-start->assistant-panel#draftSubmissionChanged ' \
                              'turbo:submit-end->assistant-panel#draftSubmissionChanged'
        base.merge(model: @chat, scope: :chat, url: form_url)
      end

      # POST target:
      # - :new_chat → the assistant_chats collection, which creates the thread WITH
      #               its first message
      # - :reply    → the assistant chatposts endpoint (chat-scoped)
      def form_url
        return helpers.organisation_assistant_chats_path(@current_organisation) if new_chat?

        helpers.organisation_assistant_chat_chatposts_path(@current_organisation, @chat)
      end

      # THE shared contract between both modes: styling, sizing and the Stimulus
      # wiring of the message field. Restyling the composer must happen here, so
      # it can never again land on the reply form only.
      def message_field_options
        {
          rows: 1,
          placeholder: t('views.organisations.chats.composer.placeholder'),
          aria: { label: t('views.organisations.chats.composer.message_label') },
          data: { neo_chat_composer_target: 'field',
                  action: 'keydown->neo-chat-composer#submitOnEnter input->neo-chat-composer#autogrow' },
          class: MESSAGE_FIELD_CLASSES
        }
      end

      def send_label
        t('views.organisations.chats.composer.send')
      end

      # The record fields_for renders in :new_chat mode. Built here rather than
      # relying on the caller having done it, so the field cannot silently vanish.
      # Reuses an existing post so a failed create re-renders with the typed text
      # instead of an empty field.
      def first_chatpost
        @first_chatpost ||= @chat.chatposts.first || @chat.chatposts.build
      end
    end
  end
end

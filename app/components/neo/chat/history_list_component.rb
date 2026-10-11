# frozen_string_literal: true

module Neo
  module Chat
    # Earlier conversations of the assistant (S3c T1, plan §7.6).
    #
    # A STATE OF THE COMPANION PANEL, not a page and not a second frame: every
    # row navigates `assistant_panel_body`, so picking an older thread exchanges
    # what the panel shows and leaves the page underneath untouched. That is the
    # whole reason this never reused the list of the per-project chat (projekt_chat_abbau
    # removed both). That one was a different animal
    # in two ways that both bite here: it navigated the PAGE rather than the panel,
    # and it wrapped itself in a fixed <turbo-frame id="chat-list"> while the panel
    # renders on top of whatever page the reader is on, so a second element with that
    # id would be one document with two.
    #
    # What IS shared stays shared: Chat#first_message owns how a thread is named
    # in a list, here as there.
    class HistoryListComponent < ViewComponent::Base
      # The frame every link in here targets. Same literal as the shell and
      # AssistantPanelsController's views -- named once, in the component that
      # depends on it.
      FRAME_ID = 'assistant_panel_body'

      # Two surfaces, one list (S3c T2):
      #   :overlay -- companion mode, the list REPLACES the transcript in the
      #               chat frame, so it needs a way back to it.
      #   :lane    -- full view, the list stands permanently beside the chat.
      #               A back arrow there would point at what is already visible.
      VARIANTS = %i[overlay lane].freeze

      def initialize(threads:, current_organisation:, current_chat: nil, variant: :overlay)
        super()
        @threads = threads
        @current_organisation = current_organisation
        @current_chat = current_chat
        raise ArgumentError, "unknown variant #{variant.inspect}" unless VARIANTS.include?(variant)

        @variant = variant
      end

      attr_reader :threads

      # Only the overlay has somewhere to go back TO: it took the transcript's
      # place. In the lane the conversation is right there.
      def back?
        @variant == :overlay
      end

      # The row label, from the ONE bulk query rather than per row: #first_message
      # would ask the database once per thread (Prosopite fails on it, and
      # rightly). A thread whose posts are gone falls back to the same empty
      # wording #first_message gives, without going back to the database for it.
      def label_for(chat)
        labels.fetch(chat.id) { ::Chat.list_label(nil) }
      end

      def current?(chat)
        @current_chat.present? && @current_chat.id == chat.id
      end

      def path_for(chat)
        helpers.organisation_assistant_panel_path(
          organisation_id: @current_organisation.id, chat_id: chat.id
        )
      end

      # Where the back arrow goes. With a known open thread, back to exactly it;
      # without one (the panel was showing the empty composer, or ?current= named
      # something this viewer does not own) to the panel's own default, which is
      # the newest own thread. Never to a page: leaving the frame would take the
      # whole app with it.
      def back_path
        return path_for(@current_chat) if @current_chat.present?

        helpers.organisation_assistant_panel_path(organisation_id: @current_organisation.id)
      end

      # `default` rather than `short`: short carries NO year (%d.%m.), and a list
      # whose whole purpose is finding something from a while ago must not print
      # last August and this August the same way.
      def created_on(chat)
        l(chat.created_at.to_date)
      end

      private

      def labels
        @labels ||= ::Chat.list_labels_for(@threads)
      end
    end
  end
end

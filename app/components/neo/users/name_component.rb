# frozen_string_literal: true

module Neo
  module Users
    # THE render seam for a user's name TEXT (doc/user_display_name_avatar_plan.md).
    # Surface register (which spot renders what, guard-enforced):
    # docs/dokumentation/namensanzeige_flaechenregister.md
    #
    # Since 05.09.2026 (Slack model, user decision) this component only SPELLS
    # the name in the viewer's chosen mode - the picture is no longer a mode
    # but a constant companion, drawn by Neo::Users::AvatarComponent; the pair
    # comes from ApplicationHelper#viewer_user_chip.
    #
    # mode: pass explicitly to pin a spelling (the settings previews); omit it
    # and the component resolves the viewer preference via
    # helpers.viewer_name_display_mode at render time - fail-safe to 'full'
    # wherever there is no authenticated viewer (broadcast renders, component
    # specs). user: may be nil (deleted actor) - renders the unknown-user label.
    class NameComponent < ViewComponent::Base
      # text_class styles the span - a label spot like the post author header
      # carries its own typography (kept alongside class: for compatibility
      # with call sites that still pass class:).
      def initialize(user:, mode: nil, text_class: nil, **options)
        super()
        @user = user
        @explicit_mode = mode&.to_s
        @text_class = text_class
        @options = options
      end

      def call
        return tag.span(t('views.helpers.application.unknown_user'), class: css) unless user

        # title carries the untruncated full name, so abbreviated spellings
        # stay hover-discoverable.
        tag.span(user.display_name(mode: mode), class: css, title: user.display_name)
      end

      private

      attr_reader :user

      def mode
        @mode ||= @explicit_mode || helpers.viewer_name_display_mode
      end

      def css
        @text_class || @options[:class]
      end
    end
  end
end

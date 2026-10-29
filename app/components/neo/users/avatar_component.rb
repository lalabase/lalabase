# frozen_string_literal: true

module Neo
  module Users
    # The chip that PICTURES a user: the uploaded picture, initials without one.
    #
    # Split out of NameComponent on 05.09.2026. A picture is not a spelling of a
    # name: since then the picture shows ALWAYS at identity spots and the
    # name-display setting governs the SPELLING of a name only (user decision).
    #
    # ONE shape everywhere since later that day (user report: "es werden noch
    # unterschiedliche Bilder angezeigt"): the 5px-corner square the ticket
    # timeline introduced in #711 - its reasoning ("a circle would be the only
    # round shape on this screen") holds on every screen, so the mark won and
    # the temporary `shape:` option is gone, exactly as the old header comment
    # promised. `.neo-user-avatar` is the stable hook for specs and the guard
    # register; never assert on the corner radius.
    #
    # Surface register (which spot renders what, guard-enforced):
    # docs/dokumentation/namensanzeige_flaechenregister.md
    #
    # user: may be nil (deleted actor). With fallback_initials: given it draws
    # those letters (the notification list marks system events with an "S" this
    # way); without, it draws an EMPTY chip rather than nothing, so a row whose
    # author is gone keeps its text column where the rows above it are.
    #
    # A block renders INSIDE the chip (e.g. the presence dot on the team page).
    #
    # title: replaces the tooltip (the user's name by default) where the name
    # stands next to the chip anyway; the people list names the kind there.
    #
    # Lists rendering many chips must preload `user: { avatar_attachment: :blob }`
    # or the attached? check below is an N+1.
    class AvatarComponent < ViewComponent::Base
      # Identity scales: :xs (20px) for attribute rows
      # like the ticket header, :small (26px) for comments and pills, :medium
      # (32px) for team lists/settings; :detail (34px) for the membership lane.
      SIZES = {
        xs: 'w-5 h-5 text-[9px]',
        small: 'w-[26px] h-[26px] text-[10px]',
        medium: 'w-8 h-8 text-xs',
        detail: 'w-[34px] h-[34px] text-xs',
        large: 'w-[52px] h-[52px] text-[15px]'
      }.freeze

      CHIP_CLASSES = 'neo-user-avatar rounded-[5px] bg-cream-200 border border-cream-300 font-bold text-cream-900'

      def initialize(user:, size: :medium, fallback_initials: nil, **options)
        super()
        @user = user
        @size = size.to_sym
        @fallback_initials = fallback_initials
        @options = options
      end

      def call
        picture = avatar_image
        initials = picture ? tag.span(letters, hidden: true, data: { avatar_fallback_target: 'initials' }) : letters
        tag.span(safe_join([initials, picture, content].compact),
                 class: classes, title: @options.fetch(:title) { user&.display_name }, data: { controller: 'avatar-fallback' })
      end

      private

      attr_reader :user

      def letters
        user ? user.initials : @fallback_initials
      end

      # The thumb variant when a usable avatar is attached, nil otherwise
      # (initials fallback). respond_to? because Admin::User shares the
      # NameDisplay concern but deliberately has no attachment (user.rb).
      #
      # persisted?: attached? is ALSO true for a pending attachment — the file
      # the user just picked on a form whose save then failed (wrong current
      # password, a picture over the size limit). Its blob is a new record, and
      # signed_id refuses those with ArgumentError, which turns every such
      # re-render into a 500 — including the one that should show the size
      # error. Nothing is stored yet, so the honest preview is the initials.
      def avatar_image
        return unless user.respond_to?(:avatar) && user.avatar.attached?

        blob = user.avatar.blob
        return unless blob&.persisted? && blob.representable?

        image_tag(helpers.rails_storage_proxy_path(user.avatar.variant(:thumb),
                                                   expires_at: picture_url_expires_at),
                  alt: '', class: 'w-full h-full object-cover rounded-[5px]',
                  data: { avatar_fallback_target: 'image', action: 'error->avatar-fallback#showInitials' })
      end

      # The picture URL is signed with an expiry (config.active_storage.urls_expire_in,
      # 15 minutes: a leaked link dies). Left to the route, that expiry is stamped to
      # the millisecond of the render, which made every chip of the SAME picture a
      # different address: the browser could neither dedupe nor cache them, a ticket
      # list with one assignee fired 53-59 image requests per load, and Rack::Attack's
      # requests/ip budget (300 per 5 minutes) answered the list itself with 429
      # (production, 07.09.2026). Rounded to a slot of that same length, every chip
      # rendered within one slot carries one address; the browser loads it once and
      # serves the rest from cache (the proxy controller sends cache-forever headers).
      #
      # The link expires at the end of the NEXT slot, never of the current one: a page
      # rendered one second before the boundary would otherwise ask for a picture
      # whose link died before the request left the browser. A leaked link therefore
      # lives two slots at most. Slots count from the epoch, not from the wall clock.
      # nil when no expiry is configured: the route then builds the plain, unexpiring
      # address, which is stable already.
      def picture_url_expires_at(now = Time.current)
        slot = ActiveStorage.urls_expire_in.to_i
        return if slot.zero?

        slot_start = now.to_i - (now.to_i % slot)
        Time.at(slot_start + (2 * slot)).utc
      end

      def classes
        [
          'relative inline-flex items-center justify-center shrink-0',
          CHIP_CLASSES,
          SIZES.fetch(@size, SIZES[:medium]),
          @options[:class]
        ].compact.join(' ')
      end
    end
  end
end

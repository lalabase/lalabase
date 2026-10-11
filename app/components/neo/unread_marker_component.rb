# frozen_string_literal: true

module Neo
  # THE marker for "unread notifications". One look for one fact: the red pill of
  # the sidebar's Inbox item. Before 29.09.2026 seven places drew it by hand, in
  # three sizes and two colours (the cockpit used a cobalt dot).
  #
  # variant:
  #   :count - red pill with the number (capped at 99+): sidebar, org tiles,
  #            org switcher menu, cockpit
  #   :dot   - red dot without a number, where a row only needs "there is
  #            something": ticket rows, kanban cards, the org switcher header
  #
  # live: true renders the element even at zero, hidden, because a Turbo Stream
  # replace or a Stimulus target needs it in the DOM as the next target. Without
  # it, zero renders nothing.
  #
  # label: the accessible text (title + aria-label), always translated by the
  # caller. A dot without a label is decoration and gets aria-hidden.
  #
  # Any other keyword (id:, data:, class:) goes onto the element; class: is
  # appended to the marker's own classes. Every marker carries
  # data-unread-marker="count|dot".
  #
  # Guard: spec/architecture/unread_marker_guard_spec.rb.
  class UnreadMarkerComponent < ViewComponent::Base
    VARIANTS = %i[count dot].freeze
    MAX_COUNT = 99
    # red-600, not red-500: the pill carries light text, and red-500 with
    # on-fill is 3.6:1, below the 4.5:1 the mobile shell spec demands.
    BASE_CLASSES = 'shrink-0 bg-red-600 rounded-full'
    VARIANT_CLASSES = {
      count: 'inline-flex items-center justify-center min-w-[20px] h-5 px-1.5 text-[11px] font-bold text-on-fill',
      dot: 'inline-block w-2 h-2'
    }.freeze

    def initialize(count:, variant: :count, label: nil, live: false, **options)
      super()
      @count = count.to_i
      @variant = variant.to_sym
      raise ArgumentError, "unknown variant #{variant.inspect}" unless VARIANTS.include?(@variant)

      @label = label
      @live = live
      @options = options
    end

    def render?
      @live || @count.positive?
    end

    def call
      tag.span(text, **attributes)
    end

    private

    def text
      return if @variant == :dot

      @count > MAX_COUNT ? "#{MAX_COUNT}+" : @count.to_s
    end

    def attributes
      extra_class = @options[:class]
      attrs = @options.except(:class)
      # The seam's fingerprint: specs find every marker by it, whatever its styling.
      attrs[:data] = (attrs[:data] || {}).merge(unread_marker: @variant)
      attrs[:class] = [BASE_CLASSES, VARIANT_CLASSES.fetch(@variant), extra_class,
                       ('hidden' unless @count.positive?)]
      if @label
        attrs[:title] = @label
        attrs[:aria] = (attrs[:aria] || {}).merge(label: @label)
        attrs[:role] = 'img' if @variant == :dot
      elsif @variant == :dot
        attrs[:aria] = (attrs[:aria] || {}).merge(hidden: true)
      end
      attrs
    end
  end
end

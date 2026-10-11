# frozen_string_literal: true

module Neo
  # Icon-trigger + dropdown list. Originally built for the header "..." overflow
  # (rarely used page actions collected behind a single quiet trigger, keeping the
  # visible action bar to one clear hierarchy) — `icon:`/`trigger_label_key:` make it
  # reusable for other icon-triggered dropdowns (e.g. the contextual-help "?" menu,
  # doc/kontexthilfe_plan.md) without a second, near-identical component.
  # Renders nothing when no items are present (e.g. all gated by policy).
  class OverflowMenuComponent < ViewComponent::Base
    ITEM_BASE = 'flex w-full items-center gap-2 px-4 py-2 text-left text-sm ' \
                'hover:bg-cream-100 transition-colors'
    ITEM_CLASSES = "#{ITEM_BASE} text-cream-900".freeze
    # A consequential item (delete) reads red; ONE colour per item, not two
    # text-* classes fighting over the order Tailwind emitted them in.
    DANGER_ITEM_CLASSES = "#{ITEM_BASE} text-red-700".freeze

    # Optional data: lets a caller attach Stimulus wiring to an item while the
    # href stays as no-JS fallback (contextual-help drawer trigger,
    # doc/kontexthilfe_drawer_plan.md D4). Default {} renders a plain link —
    # existing consumers are unchanged. danger: true for the item that deletes.
    # **html: what a link needs beyond that (target: '_blank' to open a file
    # in a new tab, download: '' to save it), passed to link_to as it is.
    renders_many :items, lambda { |label:, url:, icon: nil, data: {}, danger: false, **html|
      link_to(url, class: danger ? DANGER_ITEM_CLASSES : ITEM_CLASSES, data: data, **html) do
        parts = []
        parts << content_tag(:i, '', class: "bi bi-#{icon}") if icon.present?
        parts << content_tag(:span, label)
        safe_join(parts)
      end
    }

    # size: forwarded to the trigger IconButtonComponent. Defaults to :medium for
    # the original "..." overflow; the contextual-help "?" passes :large so it
    # matches the h-10 header buttons (Zeit/Chat/view-toggle) it sits next to.
    def initialize(icon: 'three-dots', trigger_label_key: 'components.overflow_menu.label', size: :medium)
      super()
      @icon = icon
      @trigger_label_key = trigger_label_key
      @size = size
    end

    def render?
      items.any?
    end

    attr_reader :icon, :trigger_label_key, :size
  end
end

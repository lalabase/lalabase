# frozen_string_literal: true

# A switch between the VIEWS of one page. Two forms, decided by :variant:
#
#   :groove (default): two to four segments in ONE sunken groove (cream trough,
#     NO border) where the active position sits as a light plate, so it reads
#     as a switch and not as two buttons next to the header actions (user,
#     04.09.2026). For three to five positions of equal rank that are changed
#     often; the time list's "Übersicht | Liste" wears it. A segment shows a
#     word when the item carries a label, else its icon (a bi-* class).
#   :icon_pair: two icon tiles, 30 x 30, 2px apart, no container, no groove,
#     no tint around the pair (designer, 09.09.2026): the groove was four
#     signals for one statement (trough, plate, shadow, bold word) on a control
#     that is used seldom. Active: the neighbours' hover tone (cream-100) with
#     the icon in ink, no weight, no shadow, no edge. Inactive: transparent,
#     the icon in cream-500 (the nearest token to the designer's #8A857A, the
#     same mapping the selection box made); hover and keyboard focus look like
#     the active tile. NEVER the selected tone (cream-200): in lists it means
#     "this row is chosen", in filters "this value is set", and a switch that
#     wears it as a container devalues it there. The icons are inline SVG
#     (15px, stroke 1.7, currentColor), not the icon font; :icon names one of
#     ICONS. The caption is mandatory, not decoration: title and aria-label
#     carry the word, and on keyboard focus the tooltip shows the same word
#     (components/view_switch.css), or the function is unnamed for the
#     keyboard. Both tiles always stand: a pair is readable, a lone icon not.
#     The tickets' "Liste | Kanban" wears it.
#
# Two kinds of segment, decided per item by :method:
#   :get   -> a link (navigation via query param), aria-current="page" when active
#   other  -> a button_to form (a preference written on the server), like the tickets
#
# Items: { key:, icon:, title:, label: nil, active:, path:, method: :get,
# params: {}, disabled: false }. label (optional, groove only) is a visible word
# replacing the icon; without it the icon is the whole visible label and the
# title is the tooltip AND the spoken name.
class NeoViewSwitchComponent < ViewComponent::Base
  VARIANTS = %i[groove icon_pair].freeze

  # The groove is the selected surface with an 8 px radius and 2 px of inner
  # air; the active tile is the raised surface with a 6 px radius and a very
  # flat shadow, no border of its own (designer, 08.09.2026): a switch, not a
  # button beside the main action.
  CONTAINER_CLASSES = 'inline-flex items-center h-10 p-0.5 bg-selected rounded-lg'
  SEGMENT_CLASSES = 'h-full px-3 text-sm font-medium inline-flex items-center justify-center rounded-md'
  ACTIVE_CLASSES = 'bg-surface-raised text-cream-900 shadow-[0_1px_2px_rgba(35,34,30,0.10)]'
  INACTIVE_CLASSES = 'text-cream-600 hover:text-cream-900'
  DISABLED_CLASSES = 'opacity-30 cursor-not-allowed'

  PAIR_CONTAINER_CLASSES = 'inline-flex items-center gap-0.5'
  PAIR_TILE_CLASSES = 'view-switch-tile h-[30px] w-[30px] rounded-md inline-flex items-center justify-center ' \
                      'transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink'
  PAIR_ACTIVE_CLASSES = 'bg-cream-100 text-ink'
  PAIR_INACTIVE_CLASSES = 'text-cream-500 hover:bg-cream-100 hover:text-ink focus-visible:bg-cream-100 focus-visible:text-ink'

  # The two signs, drawn on a 16-grid as tag name and attributes (rendered
  # through the tag helpers, nothing marked safe by hand): the list as three
  # horizontal strokes, the board as a frame with two dividers, the second
  # shorter.
  ICONS = {
    list: [[:path, { d: 'M2.5 4h11M2.5 8h11M2.5 12h11' }]],
    kanban: [[:rect, { x: 1.85, y: 2.35, width: 12.3, height: 11.3, rx: 1.5 }],
             [:path, { d: 'M6 2.35v11.3M10.15 2.35v7.2' }]]
  }.freeze

  # label: the accessible name of the whole switch ("Ansicht"); container_class:
  # extra classes on the box (the tickets hide theirs on phones).
  def initialize(label:, items:, container_class: nil, variant: :groove)
    super()
    raise ArgumentError, "unknown variant #{variant.inspect}" unless VARIANTS.include?(variant)

    @label = label
    @variant = variant
    @items = items.map { |item| { method: :get, params: {}, disabled: false }.merge(item) }
    @extra_classes = container_class
  end

  private

  attr_reader :label, :items, :variant

  def icon_pair?
    variant == :icon_pair
  end

  def container_classes
    [icon_pair? ? PAIR_CONTAINER_CLASSES : CONTAINER_CLASSES, @extra_classes].compact.join(' ')
  end

  def segment_classes(item)
    if icon_pair?
      [PAIR_TILE_CLASSES,
       item[:active] ? PAIR_ACTIVE_CLASSES : PAIR_INACTIVE_CLASSES,
       (DISABLED_CLASSES if item[:disabled])].compact.join(' ')
    else
      [SEGMENT_CLASSES,
       item[:active] ? ACTIVE_CLASSES : INACTIVE_CLASSES,
       (DISABLED_CLASSES if item[:disabled])].compact.join(' ')
    end
  end

  # The attributes every segment carries; the pair adds the spoken name and
  # the tooltip's word, both the title.
  def segment_attributes(item)
    attributes = { class: segment_classes(item), title: item[:title] }
    attributes.merge!('aria-label': item[:title], 'data-tip': item[:title]) if icon_pair?
    attributes
  end

  def icon_svg(item)
    parts = ICONS.fetch(item[:icon].to_sym) { raise ArgumentError, "unknown icon #{item[:icon].inspect}" }
    drawing = safe_join(parts.map { |name, attributes| tag.public_send(name, nil, **attributes) })
    tag.svg(drawing, viewBox: '0 0 16 16', width: 15, height: 15, fill: 'none', stroke: 'currentColor',
                     'stroke-width': '1.7', 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
                     'aria-hidden': true)
  end

  def links_only?
    items.all? { |item| item[:method] == :get }
  end
end

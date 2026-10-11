# frozen_string_literal: true

# The look of one sidebar row, handed out from one place.
#
# It was written out by hand at five call sites (_navigation_item,
# _global_search_nav_item, _account_nav_subitem, the assistant button in
# _navigation_application, NeoSidebarProjectItemComponent). Every one of them
# carried the same class string, and when the shell went one step darker
# (designer, 07.09.2026) every one of them had to be corrected in the same way.
# A rule that has to be applied by hand in five places is not a convention, it
# is a missing component.
#
# What the classes mean lives in app/assets/stylesheets/components/sidebar_nav.css;
# only the box (spacing, radius, layout) stays in Tailwind, because that part
# really is per call site - the account sub-items sit tighter than the main rows.
module SidebarNavHelper
  ROW_BASE = 'sidebar-row flex items-center gap-2 text-sm cursor-pointer rounded transition-colors'
  ROW_SPACING = 'px-4 py-2'

  # `spacing: nil` for a caller that sets its own padding.
  def sidebar_row_classes(active:, spacing: ROW_SPACING, extra: nil)
    [ROW_BASE, spacing, ('sidebar-row--active' if active), extra].compact.join(' ')
  end

  # The icon inside such a row. A class rather than a colour, so the row's own
  # state decides it (see the stylesheet's .sidebar-row--active .sidebar-row__icon).
  def sidebar_row_icon_classes(extra = nil)
    ['sidebar-row__icon shrink-0', extra].compact.join(' ')
  end
end

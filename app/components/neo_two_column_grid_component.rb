# frozen_string_literal: true

# Two-column grid layout for views without a categories/SmartFolder sidebar.
# Used by the Tickets index when the filter bar replaces the sidebar.
# Slots: list, main_content, panel (no categories).
class NeoTwoColumnGridComponent < ViewComponent::Base
  # Everything above the grid on a page that renders it: the layout's own top
  # padding, the title box and its gap. The grid takes the rest of the viewport.
  #
  # ⚠️ A caller whose chrome differs passes its own. The lane pages do: since
  # 07.09.2026 (tickets) and 10.09.2026 (knowledge) BOTH the page title and the
  # filter bar live inside the list column, so almost nothing stands above the
  # grid - only the layout's own top padding. One number for every page was
  # right only while every page was built the same.
  #
  # ⚠️ Both numbers are derived, not measured: 252 minus the title block (~74px
  # including its gap) minus the bar (~62px). Check in a browser - too large
  # leaves dead space under the grid, too small makes the page scroll.
  DEFAULT_CHROME_HEIGHT_PX = 252
  LANE_CHROME_HEIGHT_PX = 100

  renders_one :list
  renders_one :main_content
  renders_one :panel
  # The column picker (doc/spaltenwahl_plan.md S2): a grid child of its own,
  # never the .panel lane (see layout.css, "The column picker").
  renders_one :side_panel

  def initialize(
    selected_item: nil,
    context_type: :tickets,
    css_classes: nil,
    additional_targets: {},
    panel_close_title: nil,
    chrome_height: DEFAULT_CHROME_HEIGHT_PX,
    # The rebuilt list-and-lane layout (layout.css, ".layout--lane"): the page
    # head lives INSIDE the list column, so the grid starts at the top of the
    # content area and the lane carries the one 24px inset. ONE flag, because
    # it is one decision - a page either is built this way or it is not, and
    # two booleans that are always set together are a rule nobody can hold.
    lane: false
  )
    @selected_item = selected_item
    @context_type = context_type.to_sym
    @css_classes = css_classes
    @additional_targets = additional_targets
    @chrome_height = chrome_height
    @lane = lane
    # Tooltip on the lane close-X. Defaults to "close chat"; the meetings-analyses
    # lane passes its own label so the X does not read "close chat" over analyses.
    @panel_close_title = panel_close_title
  end

  private

  attr_reader :selected_item, :context_type, :css_classes, :additional_targets, :panel_close_title,
              :chrome_height, :lane

  def grid_classes
    base = 'layout two-column'
    base += ' layout--lane' if lane
    if css_classes.present?
      [base, css_classes].compact.join(' ')
    else
      [
        base,
        selected_item ? '' : 'hide-content',
        'hide-panel'
      ].compact.join(' ')
    end
  end

  def list_container_id
    case context_type
    when :tickets
      'tickets-list'
    when :knowledge
      'knowledge-list'
    when :meetings
      'meetings-list'
    else
      'items-list'
    end
  end

  def grid_controller_attributes
    base_attributes = {
      'data-layout-toggle-target' => 'layout'
    }

    # Keyed per context so each area remembers its own split; meeting widths
    # must not change ticket or knowledge widths.
    # ⚠️ The data-controller itself is written in the TEMPLATE, as a literal:
    # spec/architecture/stimulus_controller_wiring_spec greps the markup for it
    # and cannot see a string built in Ruby. A mount nobody can grep counts as
    # no mount, and the census is only worth something if it can be trusted.
    base_attributes['data-lane-split-storage-key-value'] = context_type.to_s if lane

    additional_targets.each do |key, value|
      base_attributes["data-#{key}"] = value
    end

    base_attributes
  end
end

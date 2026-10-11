# frozen_string_literal: true

module Dashboards
  # Shared layout-structure validation for dashboard-style configs (the project
  # DashboardConfiguration + the organisation OverviewConfiguration). The widget
  # set differs per surface, so the including model supplies it via the class
  # method `widget_registry`; everything else (the 6-unit row constraint, the
  # per-widget units bounds, the item-limit whitelist) is identical and lives
  # here exactly once. Uniqueness/cascade validations stay on each model — they
  # scope on different columns (project_id vs organisation_id).
  module ConfigValidations
    extend ActiveSupport::Concern

    included do
      validate :validate_layout_structure
    end

    private

    # The widget registry of the including model's surface (project vs overview).
    def widget_registry
      self.class.widget_registry
    end

    # Shared "is there already a default config (user_id NULL) for this surface scope?" query.
    #
    # WHY this lives here but the validate methods do NOT: the QUERY is identical for both surfaces
    # (find a sibling default, exclude self on update), so it is shared. The validation itself stays
    # on each model because the scope column (project_id vs organisation_id) AND the error key differ
    # (:project_default_exists vs :org_default_exists) — keeping the keys per-model lets the i18n
    # messages stay surface-specific. This check is belt-and-suspenders to the partial unique DB
    # index: it turns a raw RecordNotUnique into a friendly, attributed validation error.
    def default_config_exists?(scope_column)
      siblings = self.class.where(user_id: nil, scope_column => self[scope_column])
      siblings = siblings.where.not(id: id) if persisted?
      siblings.exists?
    end

    def validate_layout_structure
      return if layout.blank?

      unless layout.is_a?(Array)
        errors.add(:layout, :not_an_array)
        return
      end

      layout.each_with_index do |row, idx|
        validate_row(row, idx)
      end
    end

    def validate_row(row, idx)
      unless row.is_a?(Hash) && row['widgets'].is_a?(Array)
        errors.add(:layout, :row_missing_widgets, row: idx + 1)
        return
      end

      validate_units_sum(row, idx)
      validate_widgets(row['widgets'], idx)
    end

    # Σ units must fit the row's 6-unit track (ROW_UNITS). A missing/invalid per-widget units value
    # counts as the widget's registered minimum (Dashboards::LayoutEngine.widget_units), so the sum
    # stays meaningful.
    def validate_units_sum(row, idx)
      total = Array(row['widgets']).reject(&:blank?)
                                   .sum { |widget| Dashboards::LayoutEngine.widget_units(widget, registry: widget_registry) }
      return if total <= Dashboards::LayoutEngine::ROW_UNITS

      errors.add(:layout, :row_units_exceeds, row: idx + 1, max: Dashboards::LayoutEngine::ROW_UNITS)
    end

    def validate_widgets(widgets, row_idx)
      widgets.each do |widget|
        next if widget.blank?
        next if widget.is_a?(String)

        if widget.is_a?(Hash) && widget['key'].present?
          validate_widget_units(widget, row_idx)
          validate_widget_limit(widget, row_idx)
          next
        end

        errors.add(:layout, :widget_invalid_format, row: row_idx + 1)
      end
    end

    # Per-widget units: absent = default (valid, falls back to the registry minimum). When present
    # it must be an integer within [registry minimum, ROW_UNITS]. Unknown keys carry no registry
    # minimum, so 1 is used as the floor.
    def validate_widget_units(widget, row_idx)
      return unless widget.key?('units')

      units = widget['units']
      key = widget['key']
      min = widget_registry.dig(key, :units) || 1

      return if units.is_a?(Integer) && units >= min && units <= Dashboards::LayoutEngine::ROW_UNITS

      errors.add(:layout, :widget_units_invalid, row: row_idx + 1, widget: key, min: min, max: Dashboards::LayoutEngine::ROW_UNITS)
    end

    # Per-widget item count: absent = default (valid). When present it must be a whitelisted option
    # from LIST_LIMIT_OPTIONS. Key-agnostic so a forged limit on any widget is rejected.
    def validate_widget_limit(widget, row_idx)
      return unless widget.key?('limit')
      return if widget['limit'].is_a?(Integer) && Dashboards::LayoutEngine::LIST_LIMIT_OPTIONS.include?(widget['limit'])

      errors.add(:layout, :widget_limit_invalid, row: row_idx + 1, widget: widget['key'])
    end
  end
end

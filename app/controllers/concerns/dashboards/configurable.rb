# frozen_string_literal: true

module Dashboards
  # Shared inline-editor orchestration for dashboard-style config controllers (the project
  # DashboardConfigurationsController + the organisation OverviewConfigurationsController).
  #
  # WHAT STAYS PER CONTROLLER (deliberately not shared): edit/update, load_edit_data, save_scope and
  # the save methods — they genuinely diverge (the project dashboard has 4 save scopes with
  # cross-project transactions + smart folders; the overview has 2 org scopes). WHAT LIVES HERE ONCE:
  # the surface-agnostic pieces of the write/preview path, parameterised by the including controller's
  # registry + component context.
  #
  # The including controller supplies the surface via these hooks:
  #   editor_widget_registry        -> the surface's widget registry (build_widget / no-access)
  #   editor_base_params            -> component constructor context ({ project:, user: } for the
  #                                    project dashboard; { organisation:, user:, briefing: } for the overview)
  #   editor_configuration(layout)  -> a fresh, unsaved config record carrying `layout` (error re-render)
  #   load_edit_data                -> sets @available_widgets (+ surface extras) used by the edit view
  module Configurable
    extend ActiveSupport::Concern

    private

    # rows[i][widgets][j] params -> [{ 'widgets' => [<built widget>, ...] }, ...]. Widget parsing lives
    # in Dashboards::LayoutEngine (pure + unit-testable) so the save path and the live widget_preview
    # parse settings identically and can never drift. Empty rows carry no layout intent and are dropped.
    def parse_layout_from_params
      rows_param = params[:rows]
      return [] unless rows_param.is_a?(ActionController::Parameters)

      rows_param.values.map do |row|
        widgets_param = row[:widgets]
        widgets_list = if widgets_param.is_a?(ActionController::Parameters)
                         widgets_param.values
                       else
                         Array(widgets_param)
                       end

        widgets = widgets_list.filter_map { |w| Dashboards::LayoutEngine.build_widget(w, registry: editor_widget_registry) }

        next nil if widgets.empty?

        { 'widgets' => widgets }
      end.compact
    end

    # Renders ONE widget with the (still unsaved) settings from the editor, so flipping a card back
    # from its settings form shows the new state immediately (WYSIWYG). Layout-free fragment.
    def render_widget_preview
      widget = params[:widget].is_a?(ActionController::Parameters) ? Dashboards::LayoutEngine.build_widget(params[:widget], registry: editor_widget_registry) : nil
      key = widget&.dig('key')
      component = widget && Dashboards::LayoutEngine.component_for_widget(widget, registry: editor_widget_registry, **editor_base_params)

      render partial: 'shared/dashboards/widget_preview',
             formats: [:html], layout: false,
             locals: { component: component,
                       widget_label: helpers.dashboard_widget_label(key, registry: editor_widget_registry),
                       no_access: Dashboards::LayoutEngine.widget_no_access?(key, @available_widgets, registry: editor_widget_registry) }
    end

    # Server backstop for the client empty-layout guard: an empty layout would silently inherit the
    # default (resolve_cascade treats [] as "no preference") while reporting success. Surface it in the
    # frame instead. [] stays valid at the model level for the cascade; the guard lives in the editor
    # write path. Reset is the intended path back to the default.
    def render_empty_layout_error(layout)
      config = editor_configuration(layout)
      config.errors.add(:layout, :empty_not_allowed)
      render_layout_error(config)
    end

    # Re-render the edit screen inside the turbo-frame with HTTP 422. layout: false keeps the body
    # frame-only (no nav/header chrome) so Turbo can match and swap the frame; @configuration carries
    # the rejected layout. `render :edit` resolves to the including controller's own edit template.
    def render_layout_error(config)
      load_edit_data
      @configuration = config
      render :edit, layout: false, status: :unprocessable_entity
    end
  end
end

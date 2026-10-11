# frozen_string_literal: true

module Neo
  # The column picker of the ticket list (doc/spaltenwahl_plan.md, S2): one
  # list of the fields a list can show, a tick means show, the position is the
  # rank. When the list is too narrow for every ticked field, the top ranks stay
  # in the header row and the rest moves under the title; the boundary line
  # (F38) sits between the last field that fits and the first that does not.
  # Docked next to the list while no detail is open (F30), floating over the
  # detail while one is (F29). Every change is saved into the view the list
  # stands on at once, no draft and no asking (user, 07.09.2026); only "für
  # alle Ansichten übernehmen" is a step of its own. A view the reader may not
  # change (shared read-only) shows its rows, but takes no tick.
  # Behaviour: column_picker_controller.js; rules: components/column_picker.css.
  #
  # A pin means: when the width runs out, this column's value moves under the
  # title instead of being dropped (designer, 07.09.2026). Number and title are
  # pinned by definition and say so without offering a control.
  #
  # available:   every column the reader may see (ViewConfiguration#available_columns)
  # chosen:      the columns the list shows now, in rank order (Tickets::ResolveColumns)
  # view_name:   the active view, for the footer ("gilt für ...")
  # fit:         how many ranked columns fit, as the server wrote it on the table
  # editable:    whether the reader may change this view's list (SmartFolderPolicy#update?)
  # apply_all_url: the endpoint of "für alle Ansichten übernehmen" (plan D5); nil hides the link
  class ColumnPickerComponent < ViewComponent::Base
    ELEMENT_ID = 'column-picker'

    # The tick is the time list's tick (user, 07.09.2026): one box for a chosen
    # thing in the app, read from its owner and not typed again.
    CHECKBOX_CLASSES = "column-picker__check #{TimeSessionsHelper::TIME_LIST_CHECKBOX_CLASSES}".freeze

    def initialize(available:, chosen:, view_name:, fit:, pinned_keys: nil, editable: true, apply_all_url: nil)
      super()
      @available = available
      @chosen = chosen
      # ⚠️ The view's WHOLE pin list, not only the pins of the chosen columns.
      # An unticked column keeps its pin, and the panel has to show it or the
      # next save would drop it: what is saved is read off these signs.
      @pinned_keys = pinned_keys
      @view_name = view_name
      @fit = fit.to_i
      @editable = editable
      @apply_all_url = apply_all_url
    end

    # Number and title first, as fixed rows (ticked, no grip, no tick to take:
    # the reader sees that they cannot go, user 07.09.2026); then the ticked
    # rows in rank order; then every other field the reader may see, in the
    # order the project defines them.
    def rows
      @rows ||= begin
        fixed = @available.select { |column| column[:required] }.map { |column| row_for(column, checked: true, fixed: true) }
        ticked = ranked_chosen.map { |column| row_for(column, checked: true) }
        chosen_keys = ranked_chosen.map { |column| column[:key] }
        rest = @available.reject { |column| column[:required] || chosen_keys.include?(column[:key]) }
        fixed + ticked + rest.map { |column| row_for(column, checked: false) }
      end
    end

    # The boundary goes before the row at this index among the TICKED rows
    # (the first that does not fit), or nowhere when everything fits.
    def boundary_before_index
      return nil if @fit >= ranked_chosen.size

      @fit
    end

    def editable?
      @editable
    end

    private

    attr_reader :view_name, :apply_all_url

    def ranked_chosen
      @ranked_chosen ||= @chosen.reject { |column| column[:required] }
    end

    def row_for(column, checked:, fixed: false)
      {
        key: column[:key].to_s,
        label: column[:label],
        min_width: column[:min_width] || ViewConfiguration.column_min_width(column),
        checked: checked,
        fixed: fixed,
        pinned: fixed || pinned_keys.include?(column[:key].to_s)
      }
    end

    # Pins come from the SAME view as the list. Without an explicit list, the
    # chosen columns answer - which is right for every caller that only has
    # those, and enough for the fixed rows.
    def pinned_keys
      @pinned_keys ||= @chosen.select { |column| column[:pinned] }.map { |column| column[:key].to_s }
    end

    # A sign without a word needs a caption, and the caption names the EFFECT,
    # not the column: what the reader gains is "stays readable when the width
    # runs out", and that sentence is the same for every row.
    def pin_title(row)
      key = if row[:fixed]
              'pin_fixed'
            else
              row[:pinned] ? 'pinned' : 'pin'
            end
      I18n.t("components.column_picker.#{key}")
    end

    def pin_label(row)
      I18n.t("components.column_picker.#{row[:pinned] ? 'pin_label_on' : 'pin_label_off'}", name: row[:label])
    end
  end
end

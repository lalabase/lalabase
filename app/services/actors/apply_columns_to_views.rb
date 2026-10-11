# frozen_string_literal: true

# app/services/actors/apply_columns_to_views.rb
#
# Tier-1 actor behind the column picker's "für alle Ansichten übernehmen"
# (doc/spaltenwahl_plan.md, D5 and S5): ONE ordered column list into the
# reader's base view of the project (ViewConfiguration) and into every matching
# view of the reader's OWN that shows in this project (project-bound and
# org-wide folders the reader owns). Views other people own or share stay
# untouched: this is the reader's exception, not a broadcast. Several records,
# one transaction, hence an actor and not a controller write. applied_count
# says how many views took the list, for the flash.
module Actors
  class ApplyColumnsToViews < BaseActor
    attr_reader :applied_count

    # Every view keeps the pins it shows today. A view with a list of its own
    # (SmartFolder#custom_columns?) keeps its stored pins and drops only the
    # retired legacy lists. A view without one followed the base view, pins
    # included; it now gets a list of its own, so the base view's pins are
    # written with it, or the list would come back without any pins.
    VIEW_COLUMNS_SQL = <<~SQL.squish
      display_columns = CASE
        WHEN jsonb_typeof(display_columns) = 'object' AND display_columns <> '{}'::jsonb
          THEN (display_columns - 'list_columns' - 'header_columns') || CAST(:columns AS jsonb)
        ELSE CAST(:columns AS jsonb) || jsonb_build_object('pinned_columns', CAST(:pins AS jsonb))
      END,
      updated_at = :now
    SQL

    def initialize(project:, current_user:, columns:, view_type: 'tickets')
      super()
      @project = project
      @current_user = current_user
      @columns = columns
      @view_type = view_type
      @applied_count = 0
    end

    def record
      @view_configuration
    end

    def perform
      @view_configuration = ViewConfiguration.for_user_project(@current_user, @project, @view_type)
      @view_configuration.organisation ||= @project.organisation
      @view_configuration.ordered_columns = @columns
      @view_configuration.save!
      @applied_count = 1

      # One statement for every own folder: the list is already the normalised,
      # known set, and a save per folder would load each one's associations
      # for nothing (an N+1 the request guard would flag).
      @applied_count += own_views.update_all([VIEW_COLUMNS_SQL, {
                                               columns: SmartFolder.display_columns_for(@columns, view_type: @view_type).to_json,
                                               pins: @view_configuration.pinned_column_keys.to_json,
                                               now: Time.current
                                             }])
    end

    private

    # Own folders of the requested list type visible in this project.
    def own_views
      SmartFolder.where(user: @current_user, organisation: @project.organisation, target_object_type: (@view_type == 'meetings' ? %w[Meeting] : %w[Ticket All]))
                 .where('project_id IS NULL OR project_id = ?', @project.id)
    end
  end
end

# frozen_string_literal: true

# app/services/actors/apply_columns_to_views.rb
#
# Tier-1 actor behind the column picker's "für alle Ansichten übernehmen"
# (doc/spaltenwahl_plan.md, D5 and S5): ONE ordered column list into the
# reader's base view of the list (ViewConfiguration) and into every matching
# view of the reader's OWN that shows in that list. Views other people own or
# share stay untouched: this is the reader's exception, not a broadcast. Several
# records, one transaction, hence an actor and not a controller write.
# applied_count says how many views took the list, for the flash.
#
# Which views show in a list depends on the list type:
#
#   tickets             project_id = the project OR IS NULL (a project list
#                       shows the org-wide folders too)
#   meetings, project   project_id = the project
#   meetings, no project ("Alle Meetings")   project_id IS NULL
#
# A meeting view without a project belongs to "Alle Meetings" and shows only
# there (meetings_uebersicht_vereinheitlichen_plan.md, decision 3). Until PR 2
# of that plan a project page still wrote into it here.
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

    # project: nil is the list of the whole organisation, which only meetings
    # have; it names its organisation, a project brings its own.
    def initialize(project:, current_user:, columns:, view_type: 'tickets', organisation: project&.organisation)
      super()
      @project = project
      @organisation = organisation
      @current_user = current_user
      @columns = columns
      @view_type = view_type
      @applied_count = 0
    end

    def record
      @view_configuration
    end

    def perform
      @view_configuration = ViewConfiguration.for_list(user: @current_user, organisation: @organisation,
                                                       project: @project, view_type: @view_type)
      @view_configuration.organisation ||= @organisation
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

    # Own folders of the requested list type that show in this list (see the
    # table in the header).
    def own_views
      if @view_type == 'meetings'
        SmartFolder.where(user: @current_user, organisation: @organisation, target_object_type: 'Meeting', project_id: @project&.id)
      else
        SmartFolder.where(user: @current_user, organisation: @organisation, target_object_type: %w[Ticket All])
                   .where('project_id IS NULL OR project_id = ?', @project.id)
      end
    end
  end
end

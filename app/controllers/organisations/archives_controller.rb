# frozen_string_literal: true

module Organisations
  # "Archivierte Objekte" (doc/archivierte_objekte_plan.md): the one page that leads
  # back out of the archive. Read-only; the actions themselves stay where they are
  # (ProjectsController#unarchive, and deletion on the project settings page).
  #
  #   archive!  ->  gone from the sidebar, gone from the briefing
  #                 |
  #                 v
  #   THIS PAGE  ->  "Wiederherstellen"  ->  ProjectsController#unarchive
  #              ->  project name        ->  project settings (deletion lives there)
  #
  # Only projects are archivable today (`archived_at` exists on projects and on
  # notifications, and notifications have their own archive in the inbox), so the
  # page renders exactly one section. A second type is one more section here.
  #
  # Nested module style, unlike its compact-style neighbours: Style/ClassAndModuleChildren
  # holds a frozen Exclude list of the existing files, and a new entry there would be a
  # new offense rather than inherited drift.
  class ArchivesController < BaseController
    # A list page that authorizes an ORG-level question instead of scoping records:
    # every row belongs to the current organisation and only account admins get in,
    # so there is no per-record scope to verify. Same pair, same reason, as
    # Organisations::PowerSearchController.
    skip_after_action :verify_policy_scoped, only: :index
    # Deliberately WITHOUT `only:`. ActiveSupport dedupes callbacks by filter symbol
    # (CallbackChain#append_one -> Callback#duplicates?), so this line REPLACES the
    # base controller's conditional verify_authorized rather than joining it. Scoped
    # to :index it would leave a second action added here later with no net at all.
    after_action :verify_authorized

    def index
      # :admin? rather than a fresh :archive? - OrganisationPolicy#admin? is already
      # `user_is_admin?`, is what five views ask for this same question, and matches
      # the gate ProjectPolicy#unarchive? demands of the action behind the button.
      authorize @current_organisation, :admin?

      # .load, because the view asks .any? before iterating: on an unloaded relation
      # that is a separate existence query on top of the fetch.
      @archived_projects = @current_organisation.projects
                                                .archived
                                                .includes(:archived_by)
                                                .order(archived_at: :desc)
                                                .load
    end
  end
end

# frozen_string_literal: true

# Single source of truth for "which projects may the current user see/pick".
#
# Every user-reachable project picker and every params[:project_id] resolution must
# go through #selectable_projects instead of current_organisation.projects, so that a
# user with access to only some projects can neither see foreign project names nor
# target them via parameter tampering. Org admins/owners keep full access (the
# underlying AccessCheck::ProjectAccessService short-circuits to all projects).
module Organisations::ProjectScoping
  extend ActiveSupport::Concern

  included do
    helper_method :selectable_projects
  end

  # Projects the current_user may read, optionally narrowed to a permission area
  # (e.g. :tickets — only projects whose tickets the user may read).
  #
  # Returns a lazy relation. Memoized per area because building the relation runs the
  # permission queries inside AccessCheck; without memoization a page that renders the
  # same picker more than once would recompute that permission logic each time.
  #
  # (No `action:` parameter on purpose: every current picker needs read access. Add one
  # here — mirroring AccessCheck#accessible_projects — once a picker needs write scope.)
  def selectable_projects(area: nil)
    @selectable_projects ||= {}
    @selectable_projects[area] ||=
      AccessCheck::ProjectAccessService.accessible_projects(
        current_user, current_organisation, area: area
      )
  end
end

# frozen_string_literal: true

# app/services/actors/save_dashboard_layout.rb
#
# Single write path behind the project-dashboard editor: persists the parsed
# layout to the target the `scope` kwarg selects — the acting user's own row or
# the shared project default (user_id NULL), for the current project or every
# accessible one (`projects` = the policy-scoped relation the controller passes
# in; authorization stays in the controller). Saving a default also clears the
# acting user's OWN personal overrides (resolve_layout prefers a personal row,
# so a leftover override would hide the fresh default); other members' rows are
# never touched. All scopes run inside the BaseActor transaction.
#
# On failure #record returns a rebuilt, re-validated config of the CURRENT
# context carrying the rejected layout — exactly what the controller's 422
# turbo-frame re-render needs (A2 contract, see Dashboards::Configurable).
#
# Deliberately mirrors Actors::SaveOverviewLayout (the org-overview surface).
# The surfaces genuinely diverge (project cascade + cross-project _all scopes
# here vs. one org-level surface there), so the duplication is intentional —
# unify when a third dashboard surface appears.

module Actors
  class SaveDashboardLayout < BaseActor
    def initialize(project:, projects:, organisation:, current_user:, layout:, scope:)
      super()
      @project = project
      @projects = projects
      @organisation = organisation
      @current_user = current_user
      @layout = layout
      @scope = scope
      @saved_config = nil
    end

    # Success: the row just written for the current project context.
    # Failure: a fresh, re-validated config carrying the rejected layout (A2).
    def record
      @saved_config || rebuilt_config
    end

    def perform
      case @scope
      when 'personal_this'
        save_single(user: @current_user)
      when 'default_this'
        save_single(user: nil)
        clear_personal_overrides([@project])
      when 'personal_all'
        save_all(user: @current_user)
      when 'default_all'
        projects = save_all(user: nil)
        clear_personal_overrides(projects)
      else
        # A scope outside the controller whitelist is a programming error, not a
        # domain failure — crash loudly (dev/test re-raise via BaseActor).
        raise ArgumentError, "Unknown save scope: #{@scope.inspect}"
      end
    rescue ActiveRecord::RecordNotUnique
      # Parallel first-time save of the same default row: the partial unique
      # index (WHERE user_id IS NULL) fires before the model validation can see
      # the other row. Map it to a domain failure instead of a 500; no retry
      # (admin-only surface, practically never concurrent).
      raise ActorError.new(
        I18n.t('activerecord.errors.models.dashboard_configuration.attributes.user_id.project_default_exists'),
        code: :conflict
      )
    end

    private

    def save_single(user:)
      config = DashboardConfiguration.find_or_initialize_by(user: user, project: @project)
      apply_layout_and_save(config)
      @saved_config = config
    end

    # Upserts one row per given project; existing rows are bulk-loaded first
    # (one query instead of N find_or_initialize_by lookups). Returns the
    # materialised project list.
    def save_all(user:)
      projects = @projects.to_a
      existing = DashboardConfiguration
                 .where(user_id: user&.id, project_id: projects.map(&:id))
                 .index_by(&:project_id)

      projects.each do |project|
        config = existing[project.id] || DashboardConfiguration.new(user: user, project: project)
        apply_layout_and_save(config)
        @saved_config = config if project == @project
      end
      projects
    end

    def apply_layout_and_save(config)
      config.organisation = @organisation
      config.layout = @layout
      config.save!
    end

    # Drops the acting user's OWN personal rows for the given projects so the
    # default they just saved is what they see; other members keep theirs.
    def clear_personal_overrides(projects)
      DashboardConfiguration
        .where(user_id: @current_user.id, project_id: projects.map(&:id))
        .delete_all
    end

    # The 422 frame re-render needs a config of the current context carrying the
    # rejected layout WITH populated errors — re-validate explicitly, because
    # the failed save may have happened on a different row (e.g. another
    # project's default in the _all scopes).
    def rebuilt_config
      config = DashboardConfiguration.for_user_project(@current_user, @project)
      config.organisation = @organisation
      config.layout = @layout
      config.valid?
      config
    end
  end
end

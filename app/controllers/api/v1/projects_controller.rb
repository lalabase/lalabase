# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < BaseController
      UUID_TYPE = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Uuid.new
      def index
        scopes = applicable_scopes

        # Empty scope list (e.g. organisation_id outside the token scope):
        # there is no org in which policy_scope could run — deliberately mark the
        # empty result as scoped instead of a tripwire error.
        skip_policy_scope if scopes.empty?

        all_projects = scopes.flat_map { |organisation, scope| projects_in_organisation(organisation, scope) }

        render json: { data: all_projects.map { |p| serialize(p) } }
      end

      # GET /api/v1/projects/:id/ticket_attribute_definitions
      # Returns the custom attributes defined in the project (in particular status values).
      def ticket_attribute_definitions
        project = ActsAsTenant.without_tenant { Project.find(params[:id]) }

        with_project_scope(project) do
          authorize project, :show?
          defs = project.ticket_attribute_definitions
                        .where(active: true)
                        .order(:position)
          render json: { data: defs.map { |d| serialize_definition(d) } }
        end
      end

      private

      # One organisation's projects for the token. Its own method so the per-organisation loop
      # has a frame of its own in the Prosopite stack (allow-listed there, bounded by the
      # organisations the token reaches, like aggregate_org_slice).
      def projects_in_organisation(organisation, scope)
        ActsAsTenant.with_tenant(organisation) do
          # Controller helper instead of Pundit.policy_scope: identical scope class,
          # but only the helper sets the tripwire's verify_policy_scoped flag.
          # ⚠️ A relation of THIS organisation, never the bare class: the helper
          # memoises per scope object, so `policy_scope(Project)` answered every
          # organisation after the first with the first one's projects (until 2026-10-02).
          scoped = policy_scope(Project.where(organisation_id: organisation.id))
          scoped = scoped.where(id: current_token.linked_project_ids(scope.organisation_id)) unless scope.all_projects?
          scoped.includes(:organisation).order(:name).to_a
        end
      end

      # [organisation, scope] pairs the token reaches right now
      # (PersonalAccessToken#organisation_scopes), organisations by Organisation.by_name. With ?organisation_id=
      # only that one, if reached; the id is normalised like ActiveRecord would (case, hyphens).
      def applicable_scopes
        scopes = current_token.organisation_scopes.index_by(&:organisation_id)
        scopes = scopes.slice(UUID_TYPE.cast(params[:organisation_id].to_s)) if params[:organisation_id].present?
        Organisation.where(id: scopes.keys).by_name.map { |org| [org, scopes.fetch(org.id)] }
      end

      def serialize(project)
        {
          id: project.id,
          name: project.name,
          description: project.description,
          archived: project.archived_at.present?,
          organisation: {
            id: project.organisation_id,
            name: project.organisation&.name
          },
          created_at: project.created_at.iso8601,
          updated_at: project.updated_at.iso8601
        }
      end

      def serialize_definition(definition)
        {
          name: definition.name,
          field_type: definition.field_type,
          labels: definition.labels,
          options: definition.options,
          section: definition.section,
          position: definition.position,
          system: definition.system?
        }
      end
    end
  end
end

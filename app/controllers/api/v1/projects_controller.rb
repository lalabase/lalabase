# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < BaseController
      UUID_TYPE = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Uuid.new

      # Deliberate opt-out from the Pundit tripwire on index: PersonalAccessTokens::ReachListing
      # asks the policy scope per organisation itself, for the MCP tool list_projects as well.
      # The helper this tripwire watches is the one it must not use (it memoises per scope
      # object). Pinned in spec/services/personal_access_tokens/reach_listing_spec.rb.
      skip_after_action :verify_policy_scoped

      def index
        projects = PersonalAccessTokens::ReachListing.new(reach: current_token.reach)
                                                     .projects(viewer: current_user, organisation_ids: organisation_ids)

        render json: { data: projects }
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

      # nil = every organisation in reach. The id is normalised like ActiveRecord would
      # (case, hyphens); one that cannot be a UUID casts to nil and matches nothing.
      def organisation_ids
        [UUID_TYPE.cast(params[:organisation_id].to_s)].compact if params[:organisation_id].present?
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

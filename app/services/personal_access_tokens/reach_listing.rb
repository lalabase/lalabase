# frozen_string_literal: true

# The organisations and projects a token reaches, as the rows an API client reads.
# One reader for both surfaces, so GET /api/v1/organisations, GET /api/v1/projects
# and the MCP tools list_organisations and list_projects cannot drift. What differs
# by surface stays with the surface: the MCP tools pick include_archived, page and
# cap the text; REST answers everything the token and its owner may see.
#
# A project shows up only when the token reaches it AND the policy scope lets its
# owner see it. That is wider than the gate of a project tool: a role holding nothing but
# time tracking sees projects in the scope and opens none. REST keeps that answer;
# openable_only narrows to what the gate opens, for a client that goes on with the id.
#
# Tenant-free: it runs before any tenant is set and sets one per organisation, the
# policy scope reads it. Asks Pundit directly: the controller helper memoises per scope
# object and only ever sets a flag on the controller, which this reader does not have.
#
# Entry point: organisations, projects
module PersonalAccessTokens
  class ReachListing
    # @param reach [PersonalAccessToken::Reach]
    def initialize(reach:)
      @reach = reach
    end

    # @return [Array<Hash>] one row per organisation in reach, in the order of the
    #   org switcher
    def organisations
      Organisation.where(id: @reach.organisation_ids).by_name.map { |organisation| organisation_row(organisation) }
    end

    # @param viewer [User] the token's owner
    # @param organisation_ids [Array<String>, nil] only these organisations; an id
    #   outside the reach adds nothing. nil means every organisation in reach.
    # @param include_archived [Boolean] false leaves archived projects out; true shows
    #   those the viewer may read, which is an admin's alone
    # @param openable_only [Boolean] true keeps what ProjectAccessService.can_access_project?
    #   opens, so every listed id passes the project gate
    # @return [Array<Hash>] one row per project, by organisation, then by name
    def projects(viewer:, organisation_ids: nil, include_archived: true, openable_only: false)
      ids = organisation_ids ? @reach.organisation_ids & organisation_ids : @reach.organisation_ids
      Organisation.where(id: ids).by_name.flat_map do |organisation|
        projects_in_organisation(organisation, viewer, include_archived:, openable_only:)
          .map { |project| project_row(project) }
      end
    end

    private

    # One organisation's projects. Its own method so the per-organisation loop has a
    # frame of its own in the Prosopite stack: spec/support/prosopite.rb allow-lists it
    # by this name, bounded by the organisations the token reaches.
    def projects_in_organisation(organisation, viewer, include_archived:, openable_only:)
      ActsAsTenant.with_tenant(organisation) do
        relation = Project.where(organisation_id: organisation.id)
        relation = relation.active unless include_archived
        relation = relation.where(id: openable_ids(viewer, organisation)) if openable_only
        linked = @reach.project_ids_for(organisation.id)
        relation = relation.where(id: linked) if linked
        Pundit.policy_scope!(viewer, relation).includes(:organisation).order(:name).to_a
      end
    end

    def openable_ids(viewer, organisation)
      AccessCheck::ProjectAccessService.openable_project_ids(viewer, organisation)
    end

    def organisation_row(organisation)
      {
        id: organisation.id,
        name: organisation.name,
        subdomain: organisation.subdomain,
        scope: @reach.project_ids_for(organisation.id).nil? ? 'all_projects' : 'selected_projects'
      }
    end

    def project_row(project)
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
  end
end

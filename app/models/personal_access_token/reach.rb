# frozen_string_literal: true

class PersonalAccessToken
  # The reach of a Personal Access Token: which organisations it may see and,
  # per organisation, which projects (every project of the organisation, or only
  # the linked ones). ONE value object for the token's contract, built from the
  # two scope tables, so a token-wide read (the HTTP inbox endpoint, the MCP tool
  # list_notifications) applies the same rule as the per-project gate
  # (#accessible_project?) instead of stopping at the organisation, which is what
  # the inbox endpoint did before: a token linked to one project listed the rows
  # of every project of that organisation.
  #
  # Tenant-free on purpose, like #accessible_project?: it reads the token's own
  # scope tables, because it is consulted BEFORE any tenant is set (the join to
  # projects only fetches each linked project's organisation). Immutable once
  # built; #project? and #project_id? are pinned against #accessible_project? in
  # the model spec so the object and ID gates cannot drift.
  class Reach
    attr_reader :organisation_ids

    # @param token [PersonalAccessToken]
    def self.from_token(token)
      scopes = token.organisation_scopes
      linked = Hash.new { |hash, org_id| hash[org_id] = [] }
      unless scopes.all?(&:all_projects?)
        ActsAsTenant.without_tenant do
          token.personal_access_token_projects.joins(:project)
               .pluck('projects.organisation_id', 'personal_access_token_projects.project_id')
               .each { |org_id, project_id| linked[org_id] << project_id }
        end
      end
      by_organisation = scopes.to_h do |scope|
        [scope.organisation_id, scope.all_projects? ? nil : linked[scope.organisation_id]]
      end
      new(project_ids_by_organisation: by_organisation)
    end

    # @param project_ids_by_organisation [Hash{String => Array<String>, nil}]
    #   nil means every project of that organisation.
    def initialize(project_ids_by_organisation:)
      @by_organisation = project_ids_by_organisation.transform_values { |ids| ids&.dup&.freeze }.freeze
      @organisation_ids = @by_organisation.keys.freeze
    end

    def organisation?(organisation_id)
      @by_organisation.key?(organisation_id)
    end

    # nil = every project of the organisation; an Array = only these. An
    # organisation outside the reach yields [] (nothing), never nil (everything).
    def project_ids_for(organisation_id)
      return [] unless organisation?(organisation_id)

      @by_organisation[organisation_id]
    end

    # The same answer as PersonalAccessToken#accessible_project?, without a query.
    def project?(project)
      return false if project.nil?

      project_id?(project.organisation_id, project.id)
    end

    # For callers that know the routing IDs before loading a project or tenant.
    def project_id?(organisation_id, project_id)
      ids = project_ids_for(organisation_id)
      ids.nil? || ids.include?(project_id)
    end
  end
end

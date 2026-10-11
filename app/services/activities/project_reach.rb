# frozen_string_literal: true

# The reach of ONE project, in the shape Activities::VisibleTo expects.
#
# Entry point: project_ids
#
# The assistant hands its Lalabase::Tools::Scope straight to VisibleTo, because
# that object already answers `project_ids(area:)` for the whole organisation.
# The project activity page asks a smaller question -- may THIS user read THIS
# area in THIS project -- and this adapter is the two-line answer, so the page
# and the assistant end up gated by the same rules rather than by two hand-built
# filters.
module Activities
  class ProjectReach
    def initialize(user:, project:)
      @user = user
      @project = project
      @policy = ProjectPolicy.new(user, project)
    end

    # => [project.id] when the area is readable here, [] otherwise. Memoised per
    # area because VisibleTo asks for some of them twice (once for the area's own
    # keys, once for the project-level union).
    def project_ids(area:)
      @project_ids ||= {}
      @project_ids[area.to_sym] ||= @policy.area_access?(area, :read) ? [@project.id] : []
    end
  end
end

# frozen_string_literal: true

# Booked minutes per project, split by billing state, for the overview view of
# the time list.
#
# Entry point: calculate_project_statistics
#
# The split uses the shared bucket vocabulary (TimeSession::BILLING_STATUS_FILTERS)
# and nothing else. It used to carry a third set of names on top of it
# (billed_duration / in_group_unbilled_duration / without_group_duration, mapped
# through a CATEGORY_BY_BUCKET constant), which forced the panel above it to
# write out its own list of three columns instead of iterating the constant.
#
# Two things every figure here has to share with the list a click on it opens,
# because the table's whole promise is that the clicked number IS the sum the
# list then shows (S5 of doc/zeiten_filterzeile_und_stand_plan.md):
#
#   * WHO sees what: TimeSessions::ViewingScope, the same owner the list's
#     policy scope asks. Without it this was a report over booked time that
#     answered from every session in the organisation, while the list beside it
#     answered from the ones the reader may see. The overview is open to
#     Finance roles, not only to admins, so the two really can differ.
#   * WHICH window: TimeSessionFilterService, the same owner that turns the
#     list's two date bounds into a WHERE on occurred_on. Converting the bounds
#     a second time here is how a table cell comes to mean a slightly different
#     day than the list it opens.
class TimeSessionStatisticsService
  # start_date/end_date are inclusive Dates, or nil for "all time" (the table's
  # default). viewing_scope is a TimeSessions::ViewingScope::OrganisationScope;
  # it is required, so no caller can quietly get an unscoped report.
  def initialize(organisation:, viewing_scope:, project_id: nil, start_date: nil, end_date: nil)
    @organisation = organisation
    @viewing_scope = viewing_scope
    @project_id = project_id
    @start_date = start_date
    @end_date = end_date
  end

  # Return: array of { project:, durations: { bucket => minutes, ... }, total_duration: }.
  # `durations` carries every bucket, zero included, so a caller can iterate the
  # constant without asking whether a key is there.
  def calculate_project_statistics
    projects = filtered_projects.to_a
    sums = grouped_duration_sums(projects.map(&:id))

    projects.map do |project|
      durations = sums.fetch(project.id, empty_durations)

      { project: project, durations: durations, total_duration: durations.values.sum }
    end
  end

  private

  def empty_durations
    TimeSession::BILLING_STATUS_FILTERS.index_with { 0 }
  end

  # Sums up all buckets in ONE grouped query instead of 3 SUMs per project.
  def grouped_duration_sums(project_ids)
    raw = scoped_sessions(project_ids)
          .group(:project_id, :billed, Arel.sql('time_session_group_id IS NULL'))
          .sum(:duration)

    raw.each_with_object(Hash.new { |hash, key| hash[key] = empty_durations }) do |((project_id, billed, without_group), duration), acc|
      bucket = TimeSession.billing_bucket_for(billed: billed, grouped: !without_group)
      acc[project_id][bucket] += duration
    end
  end

  # The visible sessions of these projects inside the chosen window. The window
  # goes through TimeSessionFilterService with the date bounds and NOTHING else
  # set: the table shows every state, every subject and every person the reader
  # may see, and only the period narrows it.
  def scoped_sessions(project_ids)
    TimeSessionFilterService.new(
      base_query: @viewing_scope.apply(TimeSession.where(project_id: project_ids)),
      start_date: @start_date&.to_s,
      end_date: @end_date&.to_s
    ).call
  end

  # The projects the reader sees time in, narrowed to this organisation. Same
  # owner as the list's project select (ViewingScope#projects), so "which
  # projects are rows here" and "which rows does the list have" answer alike.
  def filtered_projects
    projects = @viewing_scope.projects.where(organisation_id: @organisation.id).order(:name)
    projects = projects.where(id: @project_id) if @project_id.present?
    projects
  end
end

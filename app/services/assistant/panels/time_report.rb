# frozen_string_literal: true

# The rows behind a time answer, for the assistant's artefact lane (plan §8.1,
# kind `report`; S3c T3).
module Assistant
  module Panels
    # `report` is the panel kind for content that has NO page of its own: the chat
    # says "37 hours are not invoiced yet", and this shows which bookings that
    # sentence is made of. The address is the one the answer already carries — a
    # time_report citation is project plus the frozen filters (Lalabase::Citations
    # .time_report), which is why this panel needs no persisted tool payload.
    #
    # ⚠️ Every parameter here is client-settable: the lane is reachable through an
    # address a person can type. So the project is looked up inside the current
    # organisation, the tier comes from TimeSessions::ViewingScope (the one owner
    # of all/own/none, §13-9), and an unreachable report answers exactly like a
    # non-existent one — `available? == false`, no message that separates the two.
    class TimeReport
      # Rows are capped, the SUMS ARE NOT: the totals come from the database over
      # the whole filtered set, and the view says how many rows it is showing of
      # how many. A cap that stayed quiet would let somebody read a partial list
      # as the whole answer.
      ROW_LIMIT = 100

      DATE_KEYS = %i[start_date end_date].freeze

      attr_reader :project, :filters, :rows, :totals, :row_count

      def self.call(user:, organisation:, params:)
        new(user: user, organisation: organisation, params: params).call
      end

      def initialize(user:, organisation:, params:)
        @user = user
        @organisation = organisation
        @params = params || {}
      end

      def call
        @project = find_project
        return self if @project.nil?

        @viewing = TimeSessions::ViewingScope.call(user: @user, project: @project)
        # A shortcut, not the gate: `available?` below is what refuses, and a
        # mutation probe confirmed it (removing this line alone changes nothing).
        # It stays because a :none reader should not cost three queries.
        return self if @viewing.none?

        @filters = resolve_filters
        scope = filtered_scope
        @row_count = scope.count
        # Preloaded, not optional: the row component names the author and the
        # billing badge asks for the group, so a page of rows is a page of
        # queries without this (Prosopite fails the request spec, and rightly).
        @rows = scope.includes(:creator, :time_session_group)
                     .order(occurred_on: :desc).limit(ROW_LIMIT).to_a
        @totals = TimeSessions::BucketTotals.call(scope: scope)
        self
      end

      # False for: no such project in this organisation, an archived-away or
      # foreign id, and no persisted time permission. ONE answer for all three,
      # so the lane never becomes an existence oracle about other people's work.
      def available?
        return false if @project.nil? || @viewing.nil?

        # Named tiers rather than "not none": a tier that gets added later has to
        # be listed here to see anything, which is the direction a rights check
        # should fail in.
        @viewing.all? || @viewing.own?
      end

      # 'all' or 'own' — the view says which, because a total that covers only the
      # reader's own bookings and one that covers everybody's look identical.
      def tier
        @viewing&.tier
      end

      def truncated?
        row_count.to_i > ROW_LIMIT
      end

      private

      # Inside the current organisation, and through the plain association rather
      # than a tenant-free finder: an id from another organisation must not
      # resolve here even for somebody who is a member of both.
      #
      # Archived projects are deliberately still openable. They are out of the
      # assistant's SEARCH reach since S3a T3, but this panel does not search: it
      # reopens the evidence of an answer that was already given, and an answer
      # whose sources stop working the day a project is archived is worse than
      # one whose sources stay honest.
      def find_project
        id = @params[:project_id].presence
        return nil if id.nil?

        @organisation.projects.find_by(id: id)
      end

      # Only what was actually applied ends up here, so the header can never claim
      # a period the query ignored: TimeSessionFilterService swallows a malformed
      # date silently and would otherwise return a project-wide list wearing a
      # date label (the same trap SummarizeTimeSessions documents for its own
      # arguments).
      #
      # ⚠️ The bound goes through TimeSessions::DateBound, never through a bare
      # Date.strptime: a calendar parser reads "999999999-01-01" as a perfectly
      # good year, and the count in #call then dies with PG::DatetimeFieldOverflow.
      # The form check that keeps a year inside what Postgres stores lives in that
      # one owner, shared with the chat tool.
      def resolve_filters
        applied = {}
        DATE_KEYS.each do |key|
          value = TimeSessions::DateBound.call(value: @params[key])
          applied[key] = value if value
        end
        applied[:creator_id] = @params[:creator_id] if uuid?(@params[:creator_id])
        applied[:ticket_id] = @params[:ticket_id] if uuid?(@params[:ticket_id])
        applied
      end

      def uuid?(value)
        value.to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      end

      # The narrowing runs BEFORE the filters, exactly as in the chat tool: a
      # creator_id filter can then only ever shrink what the tier already allows,
      # never widen it.
      def filtered_scope
        TimeSessionFilterService.new(
          base_query: @viewing.apply(@project.time_sessions),
          project: @project,
          start_date: @filters[:start_date],
          end_date: @filters[:end_date],
          creator_id: @filters[:creator_id],
          ticket_id: @filters[:ticket_id]
        ).call
      end
    end
  end
end

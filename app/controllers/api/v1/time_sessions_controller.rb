# frozen_string_literal: true

module Api
  module V1
    class TimeSessionsController < BaseController
      include Api::V1::ReadableTicket

      idempotent :create

      # Deliberate opt-out for #open: it reads across organisations without a
      # tenant, so there is no single record to authorize. What it shows is
      # decided in TimeSessions::OpenHours: own bookings (creator_id), the
      # token's reach (organisations AND projects, PersonalAccessToken#reach),
      # the web's time-viewing rule (TimeSessions::ViewingScope) and, for each
      # row's ticket, TicketPolicy::Scope. All other actions remain
      # Pundit-required.
      skip_after_action :verify_authorized, only: :open

      MAX_PER_PAGE = 100
      DEFAULT_PER_PAGE = 25

      # GET /api/v1/tickets/:ticket_id/time_sessions
      def index
        with_readable_ticket(params[:ticket_id]) do |ticket|
          # Controller helper instead of Pundit.policy_scope: identical scope class,
          # but only the helper sets the tripwire's verify_policy_scoped flag.
          relation = policy_scope(ticket.time_sessions)
                     .includes(:creator)
                     .order(occurred_on: :desc)
          paged, total = paginate(relation)

          render json: {
            data: paged.map { |s| TimeSessions::Serializer.row(s) },
            meta: pagination_meta(total)
          }
        end
      end

      # GET /api/v1/time_sessions/open
      # Returns the current user's "open hours": not yet billed AND not yet
      # assigned to any TimeSessionGroup, across the token's reach. A booking on
      # a ticket the user may not read keeps its row, with ticket null.
      def open
        hours = TimeSessions::OpenHours.call(user: current_user, reach: current_token.reach,
                                             page: page_param, per_page: per_page_param)

        render json: {
          data: hours.rows.map { |s| serialize_open(s, hours.tickets) },
          meta: {
            page: page_param,
            per_page: per_page_param,
            total: hours.total,
            total_minutes: hours.total_minutes,
            total_hours_decimal: (hours.total_minutes / 60.0).round(2)
          }
        }
      end

      # POST /api/v1/tickets/:ticket_id/time_sessions
      def create
        with_readable_ticket(params[:ticket_id]) do |ticket, project|
          session = build_session(ticket, project)
          authorize session, :create?

          if session.save
            render json: { data: TimeSessions::Serializer.row(session) }, status: :created
          else
            render_error(error: 'validation_failed', errors: session.errors.full_messages, status: :unprocessable_entity)
          end
        end
      end

      private

      def build_session(ticket, project)
        ts = TimeSession.new(
          ticket: ticket,
          project: project,
          organisation: project.organisation,
          creator: current_user,
          occurred_on: parsed_occurred_on,
          description: session_params[:description],
          customer_description: session_params[:customer_description]
        )

        if session_params[:duration_string].present?
          ts.duration_string = session_params[:duration_string]
        elsif session_params[:duration_minutes].present?
          ts.duration = session_params[:duration_minutes].to_i
        end

        ts
      end

      def session_params
        params.require(:time_session).permit(
          :occurred_on, :duration_minutes, :duration_string,
          :description, :customer_description
        )
      end

      def parsed_occurred_on
        raw = session_params[:occurred_on]
        return Time.current if raw.blank?

        Time.zone.parse(raw.to_s) || Time.current
      rescue ArgumentError
        Time.current
      end

      def paginate(relation)
        total = relation.count
        page = page_param
        per = per_page_param
        [relation.limit(per).offset((page - 1) * per).to_a, total]
      end

      def pagination_meta(total)
        { page: page_param, per_page: per_page_param, total: total }
      end

      def page_param
        [params[:page].to_i, 1].max
      end

      def per_page_param
        raw = params[:per_page].to_i
        return DEFAULT_PER_PAGE if raw <= 0

        [raw, MAX_PER_PAGE].min
      end

      # Serializer for the open-hours view: includes project + ticket inline,
      # so that Claude does not have to fetch them separately. `tickets` holds
      # only the tickets the user may read (TimeSessions::OpenHours); any other
      # ticket, a missing one or one of another organisation shows as null.
      def serialize_open(session, tickets)
        {
          id: session.id,
          occurred_on: session.occurred_on&.iso8601,
          duration_minutes: session.duration,
          duration_hours_decimal: (session.duration / 60.0).round(2),
          description: session.description,
          customer_description: session.customer_description,
          project: build_project_payload(session),
          ticket: session.ticket_id && tickets[[session.organisation_id, session.ticket_id]],
          created_at: session.created_at.iso8601
        }
      end

      def build_project_payload(session)
        project = session.project
        # Like the ticket: a project of another organisation (broken data) is none.
        return nil unless project && project.organisation_id == session.organisation_id

        { id: project.id, name: project.name }
      end
    end
  end
end

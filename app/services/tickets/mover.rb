# frozen_string_literal: true

# Moves ONE ticket into another project: the number in the target (with a
# retry when two moves race for it), the assignments and subscriptions the
# target cannot keep, the time sessions, and the three activities (source,
# target, ticket). Shared by Actors::MoveTicket (the dialog, one ticket) and
# Actors::MoveTickets (the bulk panel, a set), so the move has one owner
# (doc/ticket_bulk_edit_plan.md, slice 7). An activity context, when given,
# sits on the ticket AND both projects for the duration, so every activity of
# the move carries the run.
#
# The retry runs inside a savepoint: a RecordNotUnique poisons the surrounding
# transaction otherwise, and the bulk actor holds one around the whole set.
#
# Entry point: call
module Tickets
  class Mover
    MAX_RETRIES = 3

    # A ticket the move refuses before it writes (a hierarchy) or gives up on
    # (the number race). No initialize of its own: the service convention
    # wants keyword arguments, an exception takes its message positionally.
    class Refused < StandardError
      attr_accessor :code

      def self.with(code, message)
        error = new(message)
        error.code = code
        error
      end
    end

    def self.call(ticket:, target_project:, current_user:, activity_context: nil)
      new(ticket: ticket, target_project: target_project, current_user: current_user,
          activity_context: activity_context).call
    end

    def initialize(ticket:, target_project:, current_user:, activity_context: nil)
      @ticket = ticket
      @source_project = ticket.project
      @target_project = target_project
      @current_user = current_user
      @activity_context = activity_context
    end

    # What the move would cost, without moving (the dialog's preflight).
    def impact
      target_users_with_access = @target_project.users_with_access(:read, :tickets).pluck(:id)

      lost_assignments = @ticket.ticket_assignments
                                .includes(:user)
                                .reject { |ta| target_users_with_access.include?(ta.user_id) }

      lost_subscriptions = NotificationSubscription
                           .where(subscribable: @ticket)
                           .includes(:user)
                           .reject { |ns| target_users_with_access.include?(ns.user_id) }

      {
        new_number: next_number,
        lost_assignments: lost_assignments.map { |ta| { id: ta.id, user_name: ta.user.full_name } },
        lost_subscriptions: lost_subscriptions.map { |ns| { id: ns.id, user_name: ns.user.full_name } },
        time_sessions_count: @ticket.time_sessions.count
      }
    end

    def call
      guard_no_hierarchy!
      preload_projects
      with_context do
        with_number_conflict_retry { perform_move }
      end
      @ticket
    end

    private

    # Sub-tasks stay within one project (parent and children share it). The
    # move writes via update_columns, which BYPASSES model validations, so the
    # invariant cannot be enforced by a Ticket validation here; both a child
    # and a parent are refused. Moving a hierarchy is a documented follow-up.
    def guard_no_hierarchy!
      return unless @ticket.parent_id.present? || @ticket.children.exists?

      raise Refused.with(:has_hierarchy, I18n.t('services.actors.move_ticket.has_hierarchy'))
    end

    # The per-project number is assigned with a bounded retry, because
    # concurrent moves into the same project race on the unique index.
    def with_number_conflict_retry(&block)
      retries = 0
      begin
        Ticket.transaction(requires_new: true, &block)
      rescue ActiveRecord::RecordNotUnique => e
        retries += 1
        retry if retries < MAX_RETRIES

        raise Refused.with(:conflict, I18n.t('services.actors.move_ticket.number_conflict', retries: MAX_RETRIES, error: e.message))
      end
    end

    # Preload organisation to avoid N+1 during activity creation.
    def preload_projects
      ActiveRecord::Associations::Preloader.new(
        records: [@ticket, @source_project, @target_project],
        associations: [:organisation]
      ).call
    end

    def with_context
      return yield unless @activity_context

      holders = [@ticket, @source_project, @target_project]
      previous = holders.map(&:activity_context)
      holders.each { |holder| holder.activity_context = @activity_context }
      yield
    ensure
      holders&.zip(previous)&.each { |holder, context| holder.activity_context = context }
    end

    def next_number
      (Ticket.where(project: @target_project).maximum(:number) || 0) + 1
    end

    def perform_move
      new_number = next_number

      target_users_with_access = @target_project.users_with_access(:read, :tickets).pluck(:id)
      @ticket.ticket_assignments
             .where.not(user_id: target_users_with_access)
             .delete_all
      NotificationSubscription
        .where(subscribable: @ticket)
        .where.not(user_id: target_users_with_access)
        .delete_all

      # The move itself bypasses the Trackable callbacks; the activities below say it.
      @ticket.update_columns(
        project_id: @target_project.id,
        number: new_number,
        updater_id: @current_user&.id,
        updated_at: Time.current
      )
      @ticket.time_sessions.update_all(project_id: @target_project.id)
      # The inbox rule measures a notification by its project and the area of its
      # subject (Notification.readable): left behind, a row would stay readable for
      # whoever reads tickets in the OLD project, with the ticket's current title.
      Notification.where(notifiable: @ticket).update_all(project_id: @target_project.id)

      @source_project.track_ticket_moved_out(@ticket, @target_project)
      @target_project.track_ticket_moved_in(@ticket, @source_project)
      @ticket.track_moved(@source_project, @target_project)

      @ticket.reload
    end
  end
end

# frozen_string_literal: true

module TimeSessions
  # The phase a booking's ticket is in, for the time list's ticket filter
  # (step 3a of doc/zeiten_weitere_filter_plan.md, E1): in backlog, in
  # progress, done. The keys, their order, their words and the tickets each
  # one finds, in ONE place.
  #
  # Entry point: KEYS, then tickets / label / valid?.
  #
  # Why phases and not status values: a status is a per-project string ("Fertig"
  # here, "Done" there), and its meaning hangs on the System Functions of its
  # option (docs/architektur/tickets_lesepfad.md). The phases are read from
  # those functions, so they mean the same in every project and the list can
  # filter across all of them.
  #
  # The values are matched over all the given projects at once, through the
  # existing owners (TicketAttributeDefinition.backlog_status_values_for /
  # closed_status_values_for, Ticket.with_status_values). That is what the
  # dashboard, the overview and the cockpit do, so the time list classifies a
  # ticket the way they do (E2), including their known limit: a value that means
  # "done" in one project counts as done in another that uses it differently.
  # Where that makes a value both backlog and done, done wins, so every ticket
  # is in exactly one phase.
  module TicketPhase
    # A ticket's life, left to right.
    KEYS = %w[backlog active done].freeze

    LABEL_KEY_PREFIX = 'views.organisations.time_sessions.index.ticket_phase_'

    class << self
      def valid?(key)
        KEYS.include?(key)
      end

      def label(key)
        I18n.t("#{LABEL_KEY_PREFIX}#{key}")
      end

      # The tickets of the given projects in the phase. `project_ids` may be an
      # array or a relation (it is used as a subquery). A key it does not know
      # finds nothing.
      #
      # "active" is everything that is neither: an untriaged ticket (no status)
      # counts as work in progress, the rule of Ticket.active_work and
      # Ticket.overdue, and so does a value without any lifecycle function.
      def tickets(key, project_ids:)
        return Ticket.none unless valid?(key)

        tickets = Ticket.where(project_id: project_ids)
        done = TicketAttributeDefinition.closed_status_values_for(project_ids)
        # Done wins over backlog. Matched across projects (E2), one value can be
        # backlog in one project and done in another, and a ticket would then
        # be in two phases at once (second review, 29.09.2026).
        backlog = TicketAttributeDefinition.backlog_status_values_for(project_ids) - done

        case key
        when 'backlog' then tickets.with_status_values(backlog)
        when 'done' then tickets.with_status_values(done)
        else tickets.excluding_status_values(backlog | done)
        end
      end
    end
  end
end

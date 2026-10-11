# frozen_string_literal: true

# The server search of the ticket picker in the "Link" modal (doc/ticket_relations_plan.md,
# revision 4, §7). Organisation level, not under a project: a relation may point into any
# project of the organisation the user may read.
#
# Security rests on policy_scope(Ticket) (TicketPolicy::Scope): a ticket in a project the user
# cannot read is never an option, and verify_policy_scoped (BaseController, index) enforces the
# call. Tickets::Lookup searches number and title only.
#
# Answers the NeoAutosuggestComponent server contract: { options: [{ value, text, detail }] }.
module Organisations
  class TicketLookupsController < Organisations::BaseController
    def index
      tickets = ::Tickets::Lookup.call(scope: policy_scope(Ticket), term: scalar_param(:q),
                                       exclude_id: scalar_param(:exclude))
      render json: { options: tickets.map { |ticket| option_for(ticket) } }
    end

    private

    def option_for(ticket)
      { value: ticket.id, text: ticket.display_title, detail: ticket.project.name }
    end

    # A nested or repeated parameter (?q[]=x) is no search term.
    def scalar_param(key)
      value = params[key]
      value.is_a?(String) ? value : nil
    end
  end
end

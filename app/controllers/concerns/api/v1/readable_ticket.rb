# frozen_string_literal: true

module Api
  module V1
    # One read gate for the REST ticket member routes and the ticket number route.
    # Missing, out-of-reach and unreadable tickets return the same 404 body;
    # readable tickets still require the action's write permission. Token write
    # refusal runs before this.
    #
    # The tenant is initially unknown, so discovery reads only organisation_id and
    # project_id without a tenant. Query counts deliberately differ for missing
    # and hidden tickets: IDs are random UUIDs, not sequential ticket numbers. The
    # contract is equal status and body, not equal queries or constant timing.
    #
    # By number (REST R1): the project is discovered the same way, then the
    # number is looked up inside THAT project only, through the same reach check
    # and policy scope. A number is unique per project, so a number never
    # resolves to a sibling project's ticket. Because numbers ARE sequential,
    # status and body are what must not tell an unknown number from a hidden one:
    # both end in the same RecordNotFound.
    module ReadableTicket
      extend ActiveSupport::Concern

      private

      def with_readable_ticket(id, preload: [], &)
        raise ActiveRecord::RecordNotFound if id.blank?

        address = ActsAsTenant.without_tenant { Ticket.where(id: id).pick(:organisation_id, :project_id) }
        read_ticket(address, { id: id }, preload, &)
      end

      # A malformed number ("abc", "0") is a missing address, not an invalid
      # argument: 404 like a UUID that names nothing.
      def with_readable_ticket_number(project_id, raw_number, preload: [], &)
        number = Lalabase::Tools::TicketNumber.parse(raw_number)
        raise ActiveRecord::RecordNotFound if project_id.blank? || number.nil?

        # The stored id, not the parameter: the reach compares ids as strings.
        address = ActsAsTenant.without_tenant { Project.where(id: project_id).pick(:organisation_id, :id) }
        read_ticket(address, { number: number }, preload, &)
      end

      def read_ticket(address, conditions, preload)
        raise ActiveRecord::RecordNotFound unless address

        organisation_id, project_id = address
        raise ActiveRecord::RecordNotFound unless current_token.reach.project_id?(organisation_id, project_id)

        ActsAsTenant.with_tenant(Organisation.find(organisation_id)) do
          relation = Ticket.where(organisation_id: organisation_id, project_id: project_id).where(conditions)
          ticket = Pundit.policy_scope!(current_user, relation).includes(:project, *preload).take!
          raise ActiveRecord::RecordNotFound unless ticket.project

          authorize ticket, :show?
          yield ticket, ticket.project
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    # One read gate for the seven REST ticket member routes. Missing, out-of-reach
    # and unreadable tickets return the same 404 body; readable tickets still
    # require the action's write permission. Token write refusal runs before this.
    #
    # The tenant is initially unknown, so discovery reads only organisation_id and
    # project_id without a tenant. Query counts deliberately differ for missing
    # and hidden tickets: IDs are random UUIDs, not sequential ticket numbers. The
    # contract is equal status and body, not equal queries or constant timing.
    module ReadableTicket
      extend ActiveSupport::Concern

      private

      def with_readable_ticket(id, preload: [])
        raise ActiveRecord::RecordNotFound if id.blank?

        address = ActsAsTenant.without_tenant { Ticket.where(id: id).pick(:organisation_id, :project_id) }
        raise ActiveRecord::RecordNotFound unless address

        organisation_id, project_id = address
        raise ActiveRecord::RecordNotFound unless current_token.reach.project_id?(organisation_id, project_id)

        ActsAsTenant.with_tenant(Organisation.find(organisation_id)) do
          relation = Ticket.where(organisation_id: organisation_id, project_id: project_id)
          ticket = Pundit.policy_scope!(current_user, relation).includes(:project, *preload).find(id)
          raise ActiveRecord::RecordNotFound unless ticket.project

          authorize ticket, :show?
          yield ticket, ticket.project
        end
      end
    end
  end
end

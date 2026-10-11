# frozen_string_literal: true

# The relations of one ticket, from its page (doc/ticket_relations_plan.md, revision 4, §4 and
# §7): new renders the "Link" modal into its frame, create and destroy call the two actors and
# answer with streams for THIS ticket.
#
# The actors check no rights. This controller does, before anything is written:
#   1. write on tickets in the project of the shown ticket: the area gate of ProjectController
#      and authorize @ticket, :update? as the first line of every action;
#   2. read on the other ticket through policy_scope(Ticket): a ticket in a project the user
#      cannot read, of another organisation, or deleted meanwhile is a 404;
#   3. removing needs the relation to be visible (TicketRelation.visible_to): what the page
#      never showed cannot be removed by its id either.
# Those 404s are streams, not a bare error page: inside the ticket frame a page without the
# frame would leave "Content missing" (review round 4 of #944). They say the same for "never
# existed", "not readable" and "gone meanwhile", so they tell nothing about other tickets.
#
# Besides the section and the hint, THIS ticket's list row (table and phone) and board card are
# redrawn, so its "Wartet" cell and hourglass follow at once (plan §8.3). Nothing goes out for
# the other ticket: no stream for its section, hint, row or card, no activity, no notification
# (plan §4, review 5). Its page and its row are right on their next load.
module Organisations
  module Tickets
    class RelationsController < Organisations::BaseController
      include ProjectController
      include TicketListColumns

      # BaseActor answers an unexpected error with this code in production instead of raising.
      # That is our failure, not the input's: a 500, and the exception text stays in the log.
      INTERNAL_CODES = %i[internal_error].freeze

      # The token of one modal instance, echoed by its form. Anything else is no token.
      MODAL_TOKEN = /\A\h{16}\z/

      before_action :set_ticket

      def new
        authorize @ticket, :update?

        @modal_token = SecureRandom.hex(8)
        render layout: false
      end

      def create
        authorize @ticket, :update?

        @modal_token = scalar_param(:modal_token).to_s[MODAL_TOKEN]
        @kind = scalar_param(:kind)
        @delay_days = TicketRelation::DELAY_KINDS.include?(@kind) ? scalar_param(:delay_days).presence : nil
        other_ticket_id = scalar_param(:other_ticket_id)
        return refuse([t('views.organisations.tickets.shared.relations.modal.pick_ticket')]) if other_ticket_id.blank?

        # Not readable, of another organisation, or deleted since it was picked.
        @other_ticket = policy_scope(Ticket).find_by(id: other_ticket_id)
        return refuse([t('views.organisations.tickets.shared.relations.modal.ticket_unavailable')], status: :not_found) if @other_ticket.nil?

        result = ::Actors::CreateTicketRelation.call(ticket: @ticket, other_ticket: @other_ticket, kind: @kind,
                                                     delay_days: @delay_days, current_user: current_user)
        return changed(t('flash.ticket_relations.created')) if result.success?
        return refuse([failed_message], status: :internal_server_error) if internal?(result)

        refuse(result.errors)
      end

      def destroy
        authorize @ticket, :update?

        # Not visible, not of this ticket, or removed by someone else on a page that was not
        # told (no broadcast, plan §8.3): the section as it is now, and the reason.
        relation = TicketRelation.visible_to(current_user, current_organisation).touching(@ticket).find_by(id: params[:id])
        return changed(t('services.actors.destroy_ticket_relation.not_found'), type: :alert, status: :not_found) if relation.nil?

        result = ::Actors::DestroyTicketRelation.call(ticket: @ticket, relation_id: relation.id, current_user: current_user)
        return changed(t('flash.ticket_relations.removed')) if result.success?
        return changed(failed_message, type: :alert, status: :internal_server_error) if internal?(result)

        # Removed by someone else in the meantime: the section as it is now, and the reason.
        changed(result.errors.to_sentence, type: :alert, status: :not_found)
      end

      private

      # ProjectController derives the area from the controller name ("relations" -> :relation),
      # which is no area and would refuse everyone. Relations are ticket writes.
      def determine_access_area
        :tickets
      end

      def set_ticket
        @ticket = @project.tickets.find(params[:ticket_id])
      end

      def internal?(result)
        INTERNAL_CODES.include?(result.code)
      end

      def failed_message
        t('views.organisations.tickets.shared.relations.modal.failed')
      end

      # The section, the hint, the list row and the board card of this ticket, the modal closed
      # (its frame emptied).
      def changed(message, type: :notice, status: :ok)
        respond_to do |format|
          format.turbo_stream do
            @flash_message = { type => message }
            @list_columns = ticket_list_columns(@project)
            render :changed, status: status
          end
          format.html { redirect_to ticket_path, type => message, status: :see_other }
        end
      end

      # The modal again, with the message and what was sent.
      def refuse(messages, status: :unprocessable_content)
        @errors = messages
        respond_to do |format|
          format.turbo_stream { render :refused, status: status }
          format.html { redirect_to ticket_path, alert: messages.to_sentence, status: :see_other }
        end
      end

      def ticket_path
        organisation_project_tickets_path(current_organisation, @project, ticket_id: @ticket.id)
      end

      # A nested or repeated parameter is no value here.
      def scalar_param(key)
        value = params[key]
        value.is_a?(String) ? value : nil
      end
    end
  end
end

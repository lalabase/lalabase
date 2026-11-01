# frozen_string_literal: true

# app/services/actors/destroy_ticket_relation.rb
#
# Removes one relation of `ticket` (doc/ticket_relations_plan.md, revision 4, §6.1). The caller
# hands in the relation it found, and this actor does not trust that object: destroy! on a row
# someone else removed succeeds silently, so it reads the row again, from either end, since
# "blocked by" on this page is the other ticket's "blocks" row. A relation that does not touch
# `ticket`, or is gone, is not found. Removing an edge cannot close a cycle, so no lock.
#
# No rights checks here: the caller makes sure the user may write tickets in the project of
# `ticket` and may see the relation (Tickets::RelationAccess#relation). No activity and no
# notification (plan §6.2).

module Actors
  class DestroyTicketRelation < BaseActor
    def initialize(ticket:, relation:, current_user:)
      super()
      @ticket = ticket
      @relation = relation
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      relation = TicketRelation.touching(@ticket).find_by(id: @relation.id)
      raise ActorError.new(I18n.t('services.actors.destroy_ticket_relation.not_found'), code: :not_found) if relation.nil?

      relation.destroy!
    end
  end
end

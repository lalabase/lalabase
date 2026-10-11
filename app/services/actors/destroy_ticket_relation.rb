# frozen_string_literal: true

# app/services/actors/destroy_ticket_relation.rb
#
# Removes one relation of `ticket` (doc/ticket_relations_plan.md, revision 4, §6.1). The
# relation is looked up from either end, since "blocked by" on this page is the other ticket's
# "blocks" row; a relation that does not touch `ticket` is not found. Removing an edge cannot
# close a cycle, so no lock.
#
# No rights checks here: the caller makes sure the user may write tickets in the project of
# `ticket` (PR 2, controller). No activity and no notification (plan §6.2).

module Actors
  class DestroyTicketRelation < BaseActor
    def initialize(ticket:, relation_id:, current_user:)
      super()
      @ticket = ticket
      @relation_id = relation_id
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      relation = TicketRelation.where(source_ticket: @ticket).or(TicketRelation.where(target_ticket: @ticket))
                               .find_by(id: @relation_id)
      raise ActorError.new(I18n.t('services.actors.destroy_ticket_relation.not_found'), code: :not_found) if relation.nil?

      relation.destroy!
    end
  end
end

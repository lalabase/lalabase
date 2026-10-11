# frozen_string_literal: true

# app/services/actors/sort_ticket_attribute_definitions.rb
#
# Tier-1 actor (mini): persists a new order for a project's ticket attribute
# definitions (drag & drop in the attribute-management screen). Each id is scoped
# to the project's own definitions, so a foreign id simply matches nothing and is
# ignored — same guarantee the inline controller code gave. The write runs in the
# BaseActor transaction; update_all bypasses callbacks (position is display-only).
module Actors
  class SortTicketAttributeDefinitions < BaseActor
    def initialize(project:, ordered_ids:, current_user:)
      super()
      @project = project
      @ordered_ids = ordered_ids
      @current_user = current_user
    end

    # Bulk reorder — no single primary record.
    def record
      nil
    end

    def perform
      @ordered_ids.each_with_index do |id, index|
        # position is display-only; bulk reorder skips callbacks by design
        @project.ticket_attribute_definitions.where(id: id).update_all(position: index)
      end
    end
  end
end

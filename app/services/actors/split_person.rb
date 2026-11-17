# frozen_string_literal: true

# app/services/actors/split_person.rb
#
# Takes a merge of the people above the organisations apart again (GET /people,
# "Zusammenführung aufheben"): the whole group goes, its entries with it, and the rows it
# joined stand alone in the viewer's list. Nothing in an organisation changes.
#
# The group is found among the viewer's OWN groups. Another person's group, a group that
# does not exist and a malformed id answer alike (:not_found, the text of an unknown
# person). Members with the same account stay one person: that is computed by the read
# and stored nowhere, so there is nothing here to take apart.
#
# The owner's groups left with fewer than two entries are deleted on the way, under the
# lock a merge of the same owner takes (Actors::MergePeople).
module Actors
  class SplitPerson < BaseActor
    NOT_FOUND = :not_found

    def initialize(group_id:, current_user:)
      super()
      @group_id = Lalabase::Uuid.dashed(group_id) if group_id.is_a?(String)
      @current_user = current_user
    end

    def record
      @group
    end

    def perform
      PersonGroup.lock_for(current_user)
      @group = PersonGroup.owned_by(current_user).find_by(id: @group_id) if @group_id
      raise ActorError.new(I18n.t('controllers.people.not_found'), code: NOT_FOUND) unless @group

      # The displayed group may contain sources virtually transferred from an account
      # alias. Persist that same grouping before deleting it, or undo leaves them joined.
      PersonGroupEntry.settle_for_owner(current_user.id)
      @group.destroy!
      PersonGroup.owned_by(current_user).leftover.delete_all
    end

    private

    attr_reader :current_user
  end
end

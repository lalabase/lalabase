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
# What goes is the merge AS THE LIST SHOWS IT: every group of the viewer that joins the
# row this group joins (People::AcrossOrganisations#merges_shown_with). Two groups can
# join one row, when the entries they name turned out to be one account; with one of them
# left behind the row would still stand merged after "undo".
#
# With source: ("<organisation id>:<entry address>", the card of a merged person) only
# that ONE source leaves: the lines of the merge that name it go, by its row and by its
# account, and the rest stay merged. The source is read the way a merge reads its entries:
# through the list, under the tenant of its organisation, with the viewer's own right
# there. A source the viewer cannot see, one the merge does not name and anything that is
# no address answer like a missing merge, and nothing goes. A merge left with one entry is
# gone with the leftovers below, so taking one of two out is dissolving it.
# A competing merge can become first after a source leaves and pull in another person.
# Read the result again under the owner lock: the source must stand alone and the other
# sources must stay together, exactly as before. Otherwise roll the transaction back.
#
# The owner's groups left with fewer than two entries are deleted on the way, under the
# lock a merge of the same owner takes (Actors::MergePeople).
module Actors
  class SplitPerson < BaseActor
    NOT_FOUND = :not_found
    CONFLICT = :conflict
    # The codes whose text is written for the viewer (see Actors::MergePeople::REFUSALS).
    REFUSALS = [NOT_FOUND, CONFLICT].freeze

    SOURCE_SEPARATOR = ':'

    # source: nil for the whole merge. Anything else names one source; what is no
    # address of one is refused, never read as "the whole merge".
    def initialize(group_id:, current_user:, source: nil)
      super()
      @group_id = Lalabase::Uuid.dashed(group_id) if group_id.is_a?(String)
      @current_user = current_user
      @source = source
    end

    def record
      @group
    end

    def perform
      PersonGroup.lock_for(current_user)
      mine = PersonGroup.owned_by(current_user)
      @group = mine.find_by(id: @group_id) if @group_id
      raise not_found unless @group

      if @source.nil?
        mine.where(id: [@group.id, *shown_with_it(mine)]).delete_all
      else
        # A refusal after the write must also undo it when our caller already owns a
        # transaction and BaseActor maps the refusal to a result inside that transaction.
        PersonGroup.transaction(requires_new: true) { take_out_source }
      end
      mine.leftover.delete_all
    end

    private

    attr_reader :current_user

    def not_found
      ActorError.new(I18n.t('controllers.people.not_found'), code: NOT_FOUND)
    end

    # The lines that name the one source, in the merges that join the row this group
    # joins. The grouping the list shows is persisted first, as for the whole merge.
    def take_out_source
      User.uncached do
        shown = People::AcrossOrganisations.new(viewer: User.find(current_user.id))
        PersonGroupEntry.settle_for_owner(current_user.id, aliases: shown.entry_aliases)
        part = named_part(shown)
        raise not_found unless part

        remaining = shown.person_with(part) - [part]
        lines = PersonGroupEntry.owned_by(current_user).where(person_group_id: shown.merges_shown_with(@group.id))
        raise not_found unless lines_naming(lines, part).delete_all.positive?

        verify_people([[part], remaining])
      end
    end

    # Each expected person is a set of visible source addresses. No contact data is read
    # here. A fresh read sees our deletion instead of the original read's cached merges.
    def verify_people(people)
      fresh = People::AcrossOrganisations.new(viewer: User.find(current_user.id))
      unchanged = people.reject(&:empty?).all? do |parts|
        first = parts.first
        address = first.address[:person_id] ? "person:#{first.address[:person_id]}" : "member:#{first.address[:user_id]}"
        found = fresh.part(first.organisation_id, address)
        found && fresh.person_with(found).to_set == parts.to_set
      end
      raise ActorError.new(I18n.t('controllers.people.split.conflict'), code: CONFLICT) unless unchanged
    end

    # The entry the source names, as the viewer may read it in that organisation.
    def named_part(shown)
      return unless @source.is_a?(String)

      organisation_id, id = @source.split(SOURCE_SEPARATOR, 2)
      organisation_id = Lalabase::Uuid.dashed(organisation_id.to_s)
      shown.part(organisation_id, id) if organisation_id && id.present?
    end

    # A stored line names an entry by its row or by the account behind it
    # (PersonGroupEntry.keys_for).
    def lines_naming(lines, part)
      part.keys.map do |organisation_id, kind, id|
        lines.where(organisation_id: organisation_id, (kind == :person ? :person_id : :user_id) => id)
      end.reduce(:or)
    end

    # The other groups that join the same row. Only a second group makes the list worth
    # reading: with one group there is nothing to settle and nothing else to take apart.
    # The displayed group may contain sources virtually transferred from an account alias:
    # that grouping is persisted first, or undo would leave them joined.
    def shown_with_it(mine)
      return [] unless mine.where.not(id: @group.id).exists?

      User.uncached do
        shown = People::AcrossOrganisations.new(viewer: User.find(current_user.id))
        PersonGroupEntry.settle_for_owner(current_user.id, aliases: shown.entry_aliases)
        shown.merges_shown_with(@group.id)
      end
    end
  end
end

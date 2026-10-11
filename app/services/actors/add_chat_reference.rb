# frozen_string_literal: true

# app/services/actors/add_chat_reference.rb
#
# Puts one object into a thread's reference collection (Bezugs-Sammlung plan
# §7.2). An actor and not a controller line, per the seam rule: this is a
# multi-step write in its own transaction -- row lock, discard what no longer
# resolves (a query per type), duplicate check, limit -- and the "single-column
# write, no side effects" argument that kept AssistantChatsController#update in
# the controller does not carry here.
#
# The question "may this object stand on this thread for this asker?" is NOT
# answered here. It is asked of the ONE owner that answers it at read time as
# well (Tools::Scope#resolve_reference); a second check written by hand is exactly
# the duplicated enforcement this feature keeps getting wrong.

module Actors
  class AddChatReference < BaseActor
    def initialize(chat:, type:, id:, current_user:)
      super()
      @chat = chat
      @type = type
      @id = id
      @current_user = current_user
    end

    def record
      @chat
    end

    def perform
      # Read-modify-write on a JSON column belongs in a row lock, inside this
      # actor's transaction: two clicks in two tabs would otherwise each write the
      # list they read, and the later one would silently drop the earlier entry.
      @chat.with_lock do
        # ONE Scope per write: the instance that resolves the addition also
        # normalises the list (see #next_list). The asker's reach is not a lookup
        # and is memoised per INSTANCE, so a second Scope.for paid for it twice,
        # under the row lock.
        scope = Lalabase::Tools::Scope.for(chat: @chat, actor: @current_user)
        added = scope&.resolve_reference(type: @type, id: @id)
        # An unresolvable object is refused with the SAME sentence the old
        # single-column path used, and without naming what was refused.
        raise ActorError.new(I18n.t('flash.assistant_chats.reference_error'), code: :unresolvable_reference) if added.nil?

        # ⚠️ ONE column, and that is E3 (plan §2.2, §10 S2). Until S2 this also
        # wrote scope_project_id, because a reference narrowed the reach and the
        # two chips would otherwise have contradicted each other. Both halves went
        # together: the reference names the SUBJECT now, the chip is the user's own
        # narrowing, and nothing writes it but the user. Writing it here would
        # overwrite a choice this route never made -- which is exactly what the
        # old coupling did, silently, on every click of a button labelled
        # "Assistent".
        # ⚠️ nil means "nothing to write" (a duplicate). It is not the same as an
        # empty list, and skipping the write is the point: every write ran the
        # normaliser, and the normaliser prunes to what resolves NOW. So a
        # duplicate -- the path that answers "success, nothing changed" -- quietly
        # deleted every reference whose project an admin had archived, and
        # un-archiving does not bring them back. The row is redrawn either way.
        list = next_list(scope, added)
        @chat.update!(scope_references: list) unless list.nil?
      end
    end

    private

    # ⚠️ Adding something that is already there is SUCCESS and changes nothing --
    # not even the order. Re-appending would move the entry to the end, which the
    # collapsed summary and the prompt both read as a different collection. It
    # stays success at the LIMIT too: a duplicate adds nothing, so refusing it
    # would answer "you already have this" with "you have too many", and the offer
    # strip would read that refusal as a rejection of a reference that stands.
    def next_list(scope, added)
      entry = Assistant::ReferenceRegistry.stored_entry(type: added.class.name, id: added.id)
      stored = Assistant::ReferenceRegistry.stored_entries_of(@chat)
                                           .map { |pair| Assistant::ReferenceRegistry.stored_entry(**pair) }
      return nil if stored.include?(entry)

      # The normaliser answers ONE question here: how many entries still resolve.
      # That is what the limit counts (see below). It does NOT decide what gets
      # written back -- that is the line at the end of this method.
      kept = Chats::ReferenceNormalizer.call(chat: @chat, actor: @current_user, scope: scope)

      # ⚠️ The limit REFUSES, out loud. Until S2 an addition to a full list
      # replaced the standing entry -- deliberate throwaway code, so that "Bezug
      # wechseln zu" would not run into a 422 in a slice meant to change nothing
      # (plan §10 S1). At ten that trade is gone: adding is adding, and silently
      # dropping the oldest to make room would be a collection that forgets.
      #
      # Counted against what is KEPT, i.e. against the entries that still resolve
      # (§7.2). A list holding three dead entries has room, and demanding that the
      # user remove chips that are not on screen would be unanswerable.
      max = Assistant::ReferenceRegistry::MAX_REFERENCES
      if kept.size >= max
        raise ActorError.new(I18n.t('flash.assistant_chats.reference_limit', count: max),
                             code: :reference_limit_reached)
      end

      # ⚠️ Prune only when the list is actually full. Below the limit the STORED
      # list is written back untouched, dead entries and all.
      #
      # The first version pruned on every add. That looked like the same rule, and
      # it was not: archiving a project is reversible, deleting the references to
      # it is not. So adding an unrelated third object to a thread of two silently
      # dropped a reference nobody had asked to remove, and un-archiving did not
      # bring it back. Same bug family as the duplicate path and the removal path,
      # both fixed one cut earlier; this was the third and most ordinary door.
      #
      # At the limit the pruning is what the user asked for: they want room. And it
      # is also forced -- Chat#scope_references_well_formed counts RAW keys against
      # MAX_REFERENCES, so a full stored list plus one more would not save.
      (stored.size >= max ? kept : stored) + [entry]
    end
  end
end

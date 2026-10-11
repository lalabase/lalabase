# frozen_string_literal: true

# app/services/actors/remove_chat_reference.rb
#
# Takes one object back out of a thread's reference collection (Bezugs-Sammlung
# plan §7.2). Twin of AddChatReference and an actor for the same reason: row lock
# plus discard plus write is a multi-step write in its own transaction.
#
# ⚠️ Removing something that is not in the list -- an unknown key, an entry that
# stopped resolving, a second click on the same cross -- is SUCCESS. A second
# answer shape for "was gone already" would be a case distinction with no use: the
# caller wanted it gone and it is gone.

module Actors
  class RemoveChatReference < BaseActor
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
      @chat.with_lock do
        # ⚠️ On the STORED list, not on the resolved one (review of #642). Pruning
        # here deleted references whose project an admin had archived -- a
        # reversible act answered with an irreversible one, and at a limit of ten
        # it could take nine at once. The READ path drops what does not resolve
        # anyway, which is what ReferenceNormalizer's own header argues about: the
        # display, not the column.
        kept = Assistant::ReferenceRegistry.stored_entries_of(@chat)
                                           .map { |pair| Assistant::ReferenceRegistry.stored_entry(**pair) }
                                           .reject { |entry| entry == removed_entry }

        # ⚠️ ONE column, and that is E3 (plan §2.2, §10 S2). Until S2 emptying the
        # list also cleared scope_project_id, because the reference had SET it.
        # Now nobody writes that column but the user, so clearing it here would
        # throw away a narrowing this route never made. The whole bookkeeping that
        # went with it is gone too: "did THIS write empty a list that had entries"
        # was a question only the project answer needed.
        @chat.update!(scope_references: kept)
      end
    end

    private

    def removed_entry
      @removed_entry ||= Assistant::ReferenceRegistry.stored_entry(type: @type, id: @id)
    end
  end
end

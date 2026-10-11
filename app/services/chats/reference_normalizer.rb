# frozen_string_literal: true

# The thread's reference list, reduced to what still resolves for its OWNER
# (Bezugs-Sammlung plan §7.2). Both reference actors run it under the row lock
# before they change anything, so the list is kept clean by the WRITE path while
# the model only ever checks form (§4.2): one number, one term, two duties.
#
# Dropped are entries that are gone, out of reach, or of a deregistered type --
# all three under ONE word, because a thread has exactly one owner and
# "resolvable" is therefore unambiguous.
#
# ⚠️ Why "out of reach" flies out too, even though rights can come back: the chip
# is gone either way (it renders the RESOLVED collection), and one click brings
# the reference back. The alternative is an invisible entry that counts against
# the limit and that nobody can remove, because there is no chip to remove it
# with. That is the worse half.
#
# ⚠️ And deliberately NOT an after_destroy on Ticket. A cross hook from every
# referenceable type into the chats table is the hidden coupling this whole plan
# exists to avoid, and it would still not cover "rights were taken away".
module Chats
  class ReferenceNormalizer
    def self.call(chat:, actor:, scope: nil)
      new(chat: chat, actor: actor, scope: scope).call
    end

    # `scope:` is the Tools::Scope a caller has already built for this chat and
    # actor (Actors::AddChatReference resolves the addition through it), handed
    # in so the asker's reach is not computed a second time under the row lock:
    # area_reach is memoised per INSTANCE. Left out, the normaliser builds its own.
    def initialize(chat:, actor:, scope: nil)
      @chat = chat
      @actor = actor
      @scope = scope
    end

    # @return [Array<Hash>] the surviving entries in STORED order, in the stored
    #   form ({'type' =>, 'id' =>}), ready to be written back.
    def call
      scope = @scope || Lalabase::Tools::Scope.for(chat: @chat, actor: @actor)
      return [] if scope.nil?

      alive = scope.references.to_set { |record| Assistant::ReferenceRegistry.key_of(record) }

      Assistant::ReferenceRegistry.stored_entries_of(@chat)
                                  .select { |entry| alive.include?(Assistant::ReferenceRegistry.key_for(**entry)) }
                                  .map { |entry| Assistant::ReferenceRegistry.stored_entry(**entry) }
    end
  end
end

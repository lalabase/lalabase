# frozen_string_literal: true

# Which content types the AI pipelines embed, and every SQL atom a reader needs to ask
# "is this record supposed to be embedded, and which project does it belong to".
#
# Entry point: entries
module Embeddings
  # THE one owner of the embeddable-type list. Three readers derive from it and build
  # their own query shape from the atoms here — deliberately three readers, because
  # their shapes cannot be one:
  #   1. Embeddings::PendingEmbeddings   — lazy AR relations, one per type, which the
  #      reprocess button (with_tenant) and the monthly catch-up (without_tenant) run
  #   2. Embeddings::IndexHealth         — ONE raw UNION, for the AI hub's query budget
  #   3. AiSyncStatusService             — counts per project and per type for the
  #      Indexierung page
  #
  # It used to be three hand-kept lists. The third (the sync page) knew four types while
  # the button worked on nine, and counted fragments of a type that does not exist
  # ('Document'); a guard held the first two together and nobody looked at the third.
  # Now a tenth type is an entry here, and the guards prove that every reader DERIVES
  # from this list instead of repeating it (content_types_spec.rb holds the list against
  # the models, index_health_pending_parity_spec.rb holds the readers against the list).
  #
  # Fail-closed: #entry_for answers nil for an unknown key.
  #
  # ⚠️ No relation is built here, and none may be: the readers materialise them in
  # DIFFERENT tenant contexts, and acts_as_tenant applies its scope when a relation is
  # constructed. A relation built at load time would raise NoTenantSet, or worse, carry
  # the wrong tenant into a reader.
  #
  # NOT the retrieval side. Lalabase::ProjectRag::ContentAreaRegistry answers which read
  # right gates a type when it is RETURNED, Fragment::TYPE_CONTEXT_PREDICATES which rows
  # may ground an answer. This list answers what gets INDEXED. Two registers for two
  # questions; ContentAreaRegistry's guard derives its type list from here (through
  # PendingEmbeddings), so the two cannot disagree about what exists.
  module ContentTypes
    # One embeddable type.
    #   key            — the stable name readers key their results by (= table name)
    #   model_name     — the ActiveRecord class, as a string so this file loads without
    #                    touching nine models; #model resolves it on demand
    #   table          — the table whose embeddings_creation_flag / embedding_creation_error
    #                    columns carry the state
    #   join           — ALWAYS applied: the join the opt-in rule itself needs (the
    #                    current-version join for documents, the parent comment for a
    #                    comment attachment). nil when the table stands alone.
    #   opt_in         — SQL: "this record is supposed to have an embedding"
    #   project_join   — applied ONLY for a per-project breakdown: the extra hop from the
    #                    table (after `join`) to the row that carries project_id
    #   project_column — SQL: the project_id expression, valid after join + project_join
    Entry = Struct.new(:key, :model_name, :table, :join, :opt_in, :project_join, :project_column,
                       keyword_init: true) do
      def model
        model_name.constantize
      end

      # How a fragment reaches its owner row, for readers that count fragments per type.
      def fragment_join
        "JOIN #{table} ON #{table}.id = fragments.fragmentable_id"
      end
    end

    module_function

    # The four state atoms, as functions of a table name. Readers compose them; the
    # composition is the reader's decision (the button retries failed records, the counts
    # report them as failed), the spelling is not.

    # A record is pending when its embedding flag is unset (NULL) or explicitly false.
    # Parenthesised so the OR always binds as a unit when interpolated into a larger
    # condition.
    def flag_pending(table)
      "(#{table}.embeddings_creation_flag IS NULL OR #{table}.embeddings_creation_flag = FALSE)"
    end

    def processed(table)
      "(#{table}.embeddings_creation_flag = TRUE)"
    end

    def failed(table)
      "(#{table}.embedding_creation_error IS NOT NULL)"
    end

    # "There is something to embed at all." Only the attachment types need it — every
    # other content type carries its own text by construction.
    #
    # ⚠️ The regex, not `<> ''`. This term has to mean exactly what Ruby's `present?`
    # means, because that is what decides on the other side: the extractor STORES
    # whatever it read, whitespace included (a PDF whose pages are empty yields "\n\n"),
    # `#process` then returns present? == false and no embedding job is ever enqueued.
    # An SQL term that only excludes the empty string would call that row pending for
    # ever, and the sync page would report work that nothing will ever do.
    # `[^[:space:]]` is the direct inverse of the pattern ActiveSupport#blank? uses.
    # NULL needs no separate arm (NULL ~ … is NULL, never TRUE) but is spelled out
    # because a reader should not have to know that to read the predicate.
    def text_present(table)
      "(#{table}.plain_text_version IS NOT NULL AND #{table}.plain_text_version ~ '[^[:space:]]')"
    end

    ENTRIES = [
      Entry.new(key: :notes, model_name: 'Note', table: 'notes', join: nil,
                opt_in: 'notes.create_embeddings = TRUE',
                project_join: nil, project_column: 'notes.project_id'),
      Entry.new(key: :posts, model_name: 'Post', table: 'posts', join: nil,
                opt_in: 'posts.create_embeddings = TRUE',
                project_join: 'JOIN tickets ON tickets.id = posts.ticket_id',
                project_column: 'tickets.project_id'),
      # Tickets always embed: there is no opt-in column, only the flag gates them.
      Entry.new(key: :tickets, model_name: 'Ticket', table: 'tickets', join: nil,
                opt_in: 'TRUE', project_join: nil, project_column: 'tickets.project_id'),
      # Only the CURRENT version of a document is embedded; older versions are history.
      # The join is part of that rule, so it is the always-on `join`, and it already
      # brings `documents` in, which is where project_id lives.
      Entry.new(key: :document_versions, model_name: 'DocumentVersion', table: 'document_versions',
                join: 'JOIN documents ON documents.current_version_id = document_versions.id',
                opt_in: 'document_versions.create_embeddings = TRUE',
                project_join: nil, project_column: 'documents.project_id'),
      # Present pages ONLY: a soft-removed page has had its fragments purged and must
      # never be re-embedded. The page carries no project of its own; its set does.
      Entry.new(key: :documentation_pages, model_name: 'DocumentationPage', table: 'documentation_pages',
                join: nil, opt_in: 'documentation_pages.removed_at IS NULL',
                project_join: 'JOIN documentation_sets ON documentation_sets.id = documentation_pages.documentation_set_id',
                project_column: 'documentation_sets.project_id'),
      # Meetings (Gespräche Slice 6) embed ONLY on the per-meeting opt-in: a de-indexed
      # meeting's transcript is PII and must never come back through a catch-up run.
      Entry.new(key: :meetings, model_name: 'Meeting', table: 'meetings', join: nil,
                opt_in: 'meetings.create_embeddings = TRUE',
                project_join: nil, project_column: 'meetings.project_id'),
      # Meeting analyses (Slice 7b, Entscheidung 5) embed ONLY when published AND
      # search-released. These are real columns — the create_embeddings METHOD on the
      # model carries the runtime guards but is not SQL-able, so the rule is spelled out
      # here: a private analysis's PII never reaches the index.
      Entry.new(key: :meeting_analyses, model_name: 'MeetingAnalysis', table: 'meeting_analyses', join: nil,
                opt_in: 'meeting_analyses.is_private = FALSE AND meeting_analyses.include_in_search = TRUE',
                project_join: 'JOIN meetings ON meetings.id = meeting_analyses.meeting_id',
                project_column: 'meetings.project_id'),
      # Attachments (04.09.2026). The text_present term is not decoration: the embedding
      # service returns early on a blank plain_text_version, so a file nobody can read
      # text from could never leave the pending state. Without it every image and archive
      # in the organisation would sit in a backlog no button can clear, and the sync page
      # would say "in progress" for ever — the same defect the ai_enabled term in
      # Embeddings::IndexHealth was added to fix.
      Entry.new(key: :ticket_documents, model_name: 'TicketDocument', table: 'ticket_documents', join: nil,
                opt_in: "ticket_documents.create_embeddings = TRUE AND #{text_present('ticket_documents')}",
                project_join: 'JOIN tickets ON tickets.id = ticket_documents.ticket_id',
                project_column: 'tickets.project_id'),
      # ⚠️ The is_private term is a THIRD condition, not a repetition of the privacy rule
      # in Fragment::TYPE_CONTEXT_PREDICATES. That one keeps a private comment's file out
      # of an ANSWER; this one keeps it out of the INDEX, because nothing can read it
      # either way: the content RAG excludes private comments outright and the app search
      # does not cover attachments at all. Embedding it would only ship the file's text to
      # the provider for a vector with no reader. Same trade Entscheidung 5 settled for a
      # private meeting analysis.
      #
      # NOT mirrored onto Post itself: a private comment's own text IS readable, by its
      # addressee, through CombinedSearchService (`visible_to_user_id = :uid`). The
      # asymmetry is the point, not an oversight.
      #
      # The parent comment is what the rule reads, so it is the always-on `join`; the hop
      # on to the ticket is only for the project breakdown.
      Entry.new(key: :post_documents, model_name: 'PostDocument', table: 'post_documents',
                join: 'JOIN posts ON posts.id = post_documents.post_id',
                opt_in: "post_documents.create_embeddings = TRUE AND #{text_present('post_documents')} " \
                        'AND posts.is_private = FALSE',
                project_join: 'JOIN tickets ON tickets.id = posts.ticket_id',
                project_column: 'tickets.project_id')
    ].freeze

    # @return [Array<Entry>] every embeddable type, in a stable order the readers share.
    def entries
      ENTRIES
    end

    # @return [Array<Symbol>] the keys, in the same order.
    def keys
      entries.map(&:key)
    end

    # @return [Entry, nil] nil for an unknown key (fail-closed).
    def entry_for(key)
      entries.find { |entry| entry.key == key.to_sym }
    end
  end
end

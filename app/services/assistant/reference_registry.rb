# frozen_string_literal: true

# Which object types the assistant's reference collection knows, and everything a
# surface needs to know about one (Bezugs-Sammlung plan §5, cut S1).
#
# Entry point: entry_for
module Assistant
  # Fail-closed by construction, after the pattern of Assistant::PanelRegistry and
  # ProjectRag::ContentAreaRegistry: an unregistered type resolves to nil and is
  # then simply not there -- no chip, no line in the system prompt, no exception.
  # The type travels in a client-settable value and in a stored column, so
  # "unknown" is a case that arrives in production, not a typo only a developer
  # can cause.
  #
  # The list is open: a new type is an entry here plus a button and a reading tool
  # (as with Meeting and the knowledge objects).
  #
  # ⚠️ This registry deliberately DUPLICATES none of the three maps that already
  # exist (ContentAreaRegistry::AREA_BY_TYPE, Citations::TYPES,
  # CitationTargets::MODEL_NAMES). It declares `area` and `citation_type` and two
  # guard specs check them AGAINST those maps
  # (spec/architecture/assistant_reference_registry_guard_spec.rb), so a fourth
  # card cannot drift away from the three that are already there.
  class ReferenceRegistry
    # How many entries a thread may carry (plan E4).
    #
    # ⚠️ Measured at the CHIP ROW, not at any tool budget. Ten entries fit the
    # collapsing list of §8.1 and read at 380px.
    #
    # ⚠️ Whether the assistant can usefully READ ten was the open question here, and
    # it is now answered from the other side. Do NOT re-derive it from
    # DEFAULT_MAX_ITERATIONS: that caps ROUNDS, and every tool_call of one response
    # runs inside a single round, so ten get_ticket calls fit in one iteration. An
    # earlier version of this comment made exactly that mistake.
    #
    # What bounds them is Runner::DEFAULT_MAX_TOOL_RESULT_CHARS: the run may append
    # a fixed number of characters of tool results in total, and calls after that are
    # refused with an error the model can read. So ten references cost a bounded amount
    # however eagerly the model reads them, and the frugality sentence in the prompt
    # (jobs.ai_chat.assistant_reference_frugality) is now a hint on top of a limit
    # rather than the only thing standing there.
    #
    # ⚠️ Counted over STORED entries (§4.2). The model counts raw; keeping the
    # list to what actually resolves is the write path's job
    # (Chats::ReferenceNormalizer). One number, one term, two duties.
    MAX_REFERENCES = 10

    # The composite key, "Ticket:<uuid>", and the ONE vocabulary for identifying a
    # reference (plan §7.1). It is the same value in the URL segment, in the POST
    # body, in data-reference-keys, and in the panel's dismissed/pending sets --
    # a pair here and a key there would be two parsers for one identity.
    #
    # Stored is still the PAIR (§4.1): a key is how a reference is NAMED, a pair
    # is how it is written down.
    KEY_SEPARATOR = ':'

    # One registered type. `reachable` and `title` are lambdas so a new type
    # brings its own policy and its own formatting instead of a branch somewhere.
    Entry = Struct.new(:type, :area, :citation_type, :reachable, :title, keyword_init: true)

    ENTRIES = {
      'Ticket' => Entry.new(
        type: 'Ticket',
        # The area ProjectPolicy#area_access? understands. It is the gate, not a
        # label: Tools::Scope resolves an entry against the asker's reach FOR
        # THIS AREA and nothing else.
        area: :tickets,
        citation_type: 'ticket',
        # ⚠️ This is the POLICY of the type, not merely its project filter. For
        # Ticket and Meeting the two coincide (the area right at the project is
        # the whole rule); for MeetingAnalysis in S3 they do not -- it is private
        # to its creator until published and carries its own visible_to scope, so
        # a plain project filter would resolve foreign private analyses. Hence the
        # actor is handed in even where this type does not need it.
        #
        # organisation_id is named explicitly rather than left to the tenant: the
        # scope that calls this is built inside jobs.
        reachable: lambda { |organisation, _actor, project_ids|
          Ticket.where(organisation_id: organisation.id, project_id: project_ids)
        },
        # One line, cut to the caller's budget. The NUMBER belongs to the surface
        # (a 380px pill affords less than a sentence in the prompt), the FORM
        # belongs to the model (Ticket#one_line_title).
        title: ->(record, max) { record.one_line_title(max: max) }
      ),
      # The knowledge objects (doc/assistent_wissen_kontext_plan.md, S4 of the
      # Bezugs-Sammlung plan). Same rule as Ticket: the area right at the project
      # is the whole policy (NotePolicy::Scope and DocumentPolicy::Scope resolve
      # through accessible_project_ids for exactly these areas), so a project
      # filter IS the type's policy here.
      'Note' => Entry.new(
        type: 'Note',
        area: :notes,
        citation_type: 'note',
        reachable: lambda { |organisation, _actor, project_ids|
          Note.where(organisation_id: organisation.id, project_id: project_ids)
        },
        title: ->(record, max) { record.one_line_title(max: max) }
      ),
      # ⚠️ Document, not DocumentVersion: the object a human points at
      # (Bezugs-Sammlung §10 S4), and the one Citations.target_of names. The
      # embedding hangs on the version, which is why AREA_BY_TYPE knows only that
      # one and the registry guard's T-1 is conditional.
      #
      # The title is the CURRENT version's, so the current versions are preloaded
      # in the type's own query: Tools::Scope resolves a whole collection at once,
      # and a lazy current_version per document would be a query per chip entry.
      'Document' => Entry.new(
        type: 'Document',
        area: :documents,
        citation_type: 'document',
        reachable: lambda { |organisation, _actor, project_ids|
          Document.where(organisation_id: organisation.id, project_id: project_ids).includes(:current_version)
        },
        title: ->(record, max) { record.one_line_title(max: max) }
      ),
      # Direct references follow MeetingPolicy's project/area rights, independent
      # of search opt-in. Analyses have their own visibility and are not included.
      # Only display metadata belongs here; GetMeeting fetches current content
      # separately, including on the explicit-reference fallback path.
      'Meeting' => Entry.new(
        type: 'Meeting',
        area: :meetings,
        citation_type: 'meeting',
        reachable: lambda { |organisation, _actor, project_ids|
          Meeting.where(organisation_id: organisation.id, project_id: project_ids)
                 .select(:id, :organisation_id, :project_id, :title, :occurred_at)
        },
        title: ->(record, max) { record.one_line_title(max: max) }
      )
    }.freeze

    # @return [Entry, nil] nil for an unregistered type (fail-closed).
    def self.entry_for(type)
      ENTRIES[type.to_s]
    end

    def self.types
      ENTRIES.keys
    end

    def self.registered?(type)
      ENTRIES.key?(type.to_s)
    end

    # "Ticket:<uuid>" from a pair. Callers that hold a record use .key_of.
    def self.key_for(type:, id:)
      "#{type}#{KEY_SEPARATOR}#{id}"
    end

    def self.key_of(record)
      key_for(type: record.class.name, id: record.id)
    end

    # The pair a key names, or nil. Fail-closed on every count: an unregistered
    # type, a malformed key and an id that is not a UUID all answer nil, which the
    # callers turn into "there is nothing here" rather than into an error.
    #
    # ⚠️ NEVER constantize. The key arrives in a URL segment and in a form field,
    # and constantize on a parameter value is exactly the Brakeman finding this
    # code base already has open elsewhere (file_downloads_controller.rb:47). The
    # type is LOOKED UP in ENTRIES; nothing else turns a string into a class.
    def self.parse_key(key)
      # rpartition, not partition: a TYPE may carry a namespace ("Foo::Bar"), the
      # id never carries a colon, so the LAST separator is the one that splits.
      type, _separator, id = key.to_s.rpartition(KEY_SEPARATOR)
      return nil unless registered?(type)

      # The canonical spelling or nothing. Postgres would find the row for
      # "ABC-..." and for the 32-hex form alike, but the key is compared as a
      # STRING -- against data-reference-keys, against the stored pair, against
      # record.id (dashed, lowercase) -- and a non-canonical id would delete
      # nothing and resolve nothing, silently.
      id = Lalabase::Uuid.canonical(id)
      return nil if id.nil?

      { type: type, id: id }
    end

    # The stored pair as a symbol hash, or nil when the entry is not one. Used by
    # everything that reads the column, so "what does a stored entry look like"
    # has one answer: a Hash with EXACTLY type and id, a registered type, and an
    # id in UUID form.
    #
    # ⚠️ The UUID check is not decoration. Without it a crooked id lands on
    # IS NULL through the ActiveRecord cast and refuses SILENTLY instead of
    # loudly (reference_activerecord_casts_invalid_uuid_to_null).
    def self.entry_from(stored)
      return nil unless stored.is_a?(Hash)
      return nil unless stored.keys.map(&:to_s).sort == %w[id type]

      parse_key(key_for(type: stored['type'] || stored[:type], id: stored['id'] || stored[:id]))
    end

    # A raw stored list as PAIRS, malformed and unregistered entries dropped. The
    # ONE implementation of "what does a stored list look like", so every reader
    # gets the same answer -- Tools::Scope resolves from a snapshot it captured,
    # Chats::ReferenceNormalizer reads the column, the write path reads it for what
    # it must leave alone. Three readers, one rule.
    #
    # ⚠️ Two entry points on purpose: a caller holding the CHAT should not have to
    # know the column's name, and a caller holding a raw list (a snapshot, a
    # parameter) cannot pass a chat. An earlier version offered only the second and
    # claimed to be "the one reader"; the other two had each copied the filter_map.
    def self.stored_entries_in(list)
      Array(list).filter_map { |stored| entry_from(stored) }
    end

    def self.stored_entries_of(chat)
      stored_entries_in(chat.scope_references)
    end

    # The stored form of a pair. The one place that spells the two keys, so the
    # column and every reader agree on them.
    def self.stored_entry(type:, id:)
      { 'type' => type.to_s, 'id' => id.to_s }
    end
  end
end

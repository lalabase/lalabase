# frozen_string_literal: true

module Documentation
  # The single source of truth for the `lalabase://<type>/<uuid>` pseudo-link that
  # ties a documentation page to a knowledge object (Note / Document).
  #
  # This is the CONTRACT SHARED by both halves of Slice 4, so the format lives in
  # ONE place, never two:
  #   * KnowledgeLinkResolver#resolve  parses it at sync time and turns a valid one
  #     into an in-app link + a Reference row.
  #   * The MCP tool `search_knowledge` builds it (via .build) so a coding agent can
  #     paste the exact string the resolver understands straight into doc markdown.
  #
  # Why a pseudo-scheme and not a real relative link: an author writing docs in the
  # external repo has no in-app URL to point at (org/project ids are Lalabase-internal),
  # but does know the knowledge object's type + UUID. The scheme carries exactly that,
  # runs through the existing Redcarpet → a[href] rewrite pipeline (one new branch next
  # to internal_page_href), and is unambiguous to match.
  module KnowledgeLink
    SCHEME = 'lalabase'

    # Registry of link-able knowledge types. A new type needs ONE entry here:
    #   model     the AR class the UUID addresses (also its polymorphic_name for the
    #             Reference target) and the tenant/project-scoped lookup root.
    #   path      lambda(routes, record) -> the in-app path the resolved link points to.
    #             `routes` is Rails' url_helpers (the renderer runs outside a view).
    #
    # Kept separate from Knowledge::TypeRegistry ON PURPOSE: that registry models the
    # Knowledge LISTING UI (icons, label keys, UNION arms) and carries no route info;
    # coupling the link contract to it would drag UI concerns into the sync path for no
    # gain. The overlap is only the type→model pair, and this is the link scheme's home.
    TYPES = {
      'note' => {
        model: 'Note',
        path: ->(routes, record) { routes.organisation_project_note_path(record.organisation_id, record.project_id, record.id) }
      },
      'document' => {
        model: 'Document',
        path: ->(routes, record) { routes.organisation_project_document_path(record.organisation_id, record.project_id, record.id) }
      }
    }.freeze

    # Matches `lalabase://<type>/<uuid>` exactly. The type must be a known key and the
    # id a dashed UUID; anything else parses to nil (→ the resolver leaves it untouched,
    # so a hallucinated or malformed link never becomes an in-app link or a 500).
    LINK_PATTERN = %r{\A#{SCHEME}://(?<type>[a-z_]+)/(?<id>\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}i

    module_function

    def type_keys
      TYPES.keys
    end

    def entry(type)
      TYPES[type.to_s]
    end

    # Type key for a record (e.g. a Note -> 'note'), or nil for an unsupported class.
    def key_for(record)
      polymorphic = record.class.polymorphic_name
      TYPES.find { |_key, entry| entry[:model] == polymorphic }&.first
    end

    # Builds the canonical link string for a knowledge record. Returns nil for an
    # unsupported record class rather than emitting a link the resolver can't honour.
    def build(record)
      key = key_for(record)
      return nil if key.nil?

      "#{SCHEME}://#{key}/#{record.id}"
    end

    # Parses a link string to { type:, id: } (both known-valid), or nil. Only the
    # shape is validated here — whether the target actually EXISTS (and is in-tenant
    # and in-project) is the resolver's job, deliberately kept out of this pure parser.
    def parse(url)
      match = LINK_PATTERN.match(url.to_s)
      return nil if match.nil?

      type = match[:type].downcase
      return nil unless TYPES.key?(type)

      # Downcase the id to its canonical (stored) form: PG accepts a mixed-case UUID but
      # returns it lowercase, so the resolver keys its lookup by the lowercase id. Without
      # this, a hand-written UPPER-CASE uuid would resolve in the DB yet miss that keying.
      { type: type, id: match[:id].downcase }
    end
  end
end

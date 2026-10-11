# frozen_string_literal: true

# == Schema Information
#
# Table name: fragments
#
#  id                 :uuid             not null, primary key
#  fragmentable_type  :string           not null
#  plain_text_content :text
#  version_token      :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  fragmentable_id    :uuid             not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  index_fragments_on_fragmentable     (fragmentable_type,fragmentable_id)
#  index_fragments_on_organisation_id  (organisation_id)
#  index_fragments_on_version_token    (version_token)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#

# app/models/fragment.rb

class Fragment < ApplicationRecord
  include PgSearch::Model

  acts_as_tenant(:organisation)

  belongs_to :fragmentable, polymorphic: true

  # Sidecar embeddings (embedding v2, PR 2). dependent: :delete_all — cheap bulk
  # delete, fires on per-row #destroy (post/document/document_version cascades and
  # the version-swap in EmbeddingProcessingService). IMPORTANT: does NOT fire when
  # fragments die via a PARENT's delete_all / a bulk purge — those paths either
  # purge the sidecar explicitly (the PII class: meeting/analysis opt-out + destroy,
  # the EPS race-guard; and Actors::DestroyPost's bulk delete_all of its
  # PostDocument fragments) or leave orphans for the PR-3 GC (note/ticket/
  # documentation page — not PII). Since PR 4b reads run over the sidecar, such an
  # orphan row cannot surface as a hit either (the M1 join in
  # Embeddings::NearestNeighbors); the daily GC still reclaims the storage.
  # See doc/embedding_v2_pr2_sidecar_plan.md §3.5.
  has_many :content_embeddings, as: :embeddable, dependent: :delete_all

  validates :version_token, presence: true
  # Polymorphic join that maps every fragment via fragmentable_type/_id onto the project
  # of its fragmentable (Note/Ticket/Meeting directly, Post → ticket, DocumentVersion →
  # document, MeetingAnalysis → meeting). SHARED source for all project-scoping fragment
  # consumers: ProjectRag::Retriever#fetch_content AND CombinedSearchService#apply_access_filter.
  #
  # ONLY the JOIN is shared — the WHERE clause is DELIBERATELY kept separate PER CONSUMER,
  # because the visibility semantics diverge: combined_search is current_user-/multi-project-
  # based and admits private posts addressed to the recipient; the content RAG is
  # single-project (chat.project) and excludes private posts entirely. The JOIN itself
  # is identical in both, hence centralized here (DRY), without mixing the WHERE
  # semantics.
  # post_tickets = ticket alias for post comments (Post → ticket → project).
  # documentation_pages → documentation_sets carries the project for doc pages
  # (Slice 3); the set holds project_id, the page only its set_id.
  # analysis_meetings = meeting ALIAS for meeting analyses (MeetingAnalysis → meeting →
  # project, Slice 7b): `meetings` is already joined above for the direct Meeting arm,
  # so the second hop needs its own alias — exactly the post_tickets pattern.
  FRAGMENTABLE_PROJECT_JOINS = <<~SQL.squish.freeze
    LEFT JOIN notes ON fragments.fragmentable_type = 'Note' AND fragments.fragmentable_id = notes.id
    LEFT JOIN meetings ON fragments.fragmentable_type = 'Meeting' AND fragments.fragmentable_id = meetings.id
    LEFT JOIN meeting_analyses ON fragments.fragmentable_type = 'MeetingAnalysis' AND fragments.fragmentable_id = meeting_analyses.id
    LEFT JOIN meetings analysis_meetings ON meeting_analyses.meeting_id = analysis_meetings.id
    LEFT JOIN tickets ON fragments.fragmentable_type = 'Ticket' AND fragments.fragmentable_id = tickets.id
    LEFT JOIN posts ON fragments.fragmentable_type = 'Post' AND fragments.fragmentable_id = posts.id
    LEFT JOIN tickets post_tickets ON posts.ticket_id = post_tickets.id
    LEFT JOIN document_versions ON fragments.fragmentable_type = 'DocumentVersion' AND fragments.fragmentable_id = document_versions.id
    LEFT JOIN documents ON document_versions.document_id = documents.id
    LEFT JOIN documentation_pages ON fragments.fragmentable_type = 'DocumentationPage' AND fragments.fragmentable_id = documentation_pages.id
    LEFT JOIN documentation_sets ON documentation_pages.documentation_set_id = documentation_sets.id
    LEFT JOIN ticket_documents ON fragments.fragmentable_type = 'TicketDocument' AND fragments.fragmentable_id = ticket_documents.id
    LEFT JOIN tickets document_tickets ON ticket_documents.ticket_id = document_tickets.id
    LEFT JOIN post_documents ON fragments.fragmentable_type = 'PostDocument' AND fragments.fragmentable_id = post_documents.id
    LEFT JOIN posts document_posts ON post_documents.post_id = document_posts.id
    LEFT JOIN tickets document_post_tickets ON document_posts.ticket_id = document_post_tickets.id
  SQL

  # Hard boundary of the content RAG (plan §4.1): exactly ONE project + private posts
  # excluded. The per-area gate (which fragmentable_types the asker may see)
  # deliberately sits in the retriever, NOT here — this scope is the
  # project/privacy boundary that always applies regardless of who is asking.
  # The DocumentationPage branch adds `documentation_pages.removed_at IS NULL` as
  # defense-in-depth: soft-removal already purges a gone page's fragments
  # (DocumentationSyncJob), but this guarantees a removed page can never ground even
  # if a fragment somehow lingers — mirroring the private-post exclusion (a per-row
  # visibility filter inside the boundary).
  # The Meeting branch adds `meetings.create_embeddings = TRUE` for the same reason:
  # toggling a meeting's search opt-in OFF deletes its fragments (Actors::SaveMeeting),
  # but this guarantees an orphaned fragment of a de-indexed meeting can never ground
  # (PII data class — plan §7 "Rohtranskript ungewollt auffindbar").
  # The MeetingAnalysis branch adds `is_private = FALSE AND include_in_search = TRUE`
  # (Slice 7b, Entscheidung 5): a private analysis is NEVER retrievable, and only a
  # search-released one grounds — the actor purges fragments on de-index, this is the
  # defense-in-depth row filter guaranteeing an orphaned fragment can never leak.
  # DELIBERATELY duplicated in CombinedSearchService (divergent WHERE semantics per
  # consumer — see the FRAGMENTABLE_PROJECT_JOINS note above; do NOT unify).
  #
  # ONE owner for the per-type privacy predicates, shared by both context scopes
  # below (single project / org-wide map). `%<bind>s` is the placeholder for the
  # per-type bind name — the org-wide scope binds a DIFFERENT project set per type
  # (per-area reach, S3a T3), so a single :pid cannot serve both forms.
  TYPE_CONTEXT_PREDICATES = {
    'Note' => "(fragments.fragmentable_type = 'Note' AND notes.project_id IN (:%<bind>s))",
    'Meeting' => "(fragments.fragmentable_type = 'Meeting' AND meetings.project_id IN (:%<bind>s) " \
                 'AND meetings.create_embeddings = TRUE)',
    'MeetingAnalysis' => "(fragments.fragmentable_type = 'MeetingAnalysis' AND analysis_meetings.project_id IN (:%<bind>s) " \
                         'AND meeting_analyses.is_private = FALSE AND meeting_analyses.include_in_search = TRUE)',
    'Ticket' => "(fragments.fragmentable_type = 'Ticket' AND tickets.project_id IN (:%<bind>s))",
    'Post' => "(fragments.fragmentable_type = 'Post' AND post_tickets.project_id IN (:%<bind>s) " \
              'AND posts.is_private = false)',
    'DocumentVersion' => "(fragments.fragmentable_type = 'DocumentVersion' AND documents.project_id IN (:%<bind>s))",
    'DocumentationPage' => "(fragments.fragmentable_type = 'DocumentationPage' " \
                           'AND documentation_sets.project_id IN (:%<bind>s) ' \
                           'AND documentation_pages.removed_at IS NULL)',
    # Attachments reach their project through their parent, and both need their OWN
    # ticket alias: `tickets` is already bound to the direct Ticket arm and `posts` to
    # the Post arm, exactly the situation post_tickets and analysis_meetings solve above.
    'TicketDocument' => "(fragments.fragmentable_type = 'TicketDocument' " \
                        'AND document_tickets.project_id IN (:%<bind>s))',
    # ⚠️ The is_private term is why PostDocument cannot borrow the TicketDocument
    # predicate: a private comment is kept out of the content layer entirely, so the file
    # hanging off it has to go the same way. Without this line the attachment is a hole
    # in the very wall its comment stands behind.
    'PostDocument' => "(fragments.fragmentable_type = 'PostDocument' " \
                      'AND document_post_tickets.project_id IN (:%<bind>s) ' \
                      'AND document_posts.is_private = false)'
  }.freeze

  scope :for_project_context, lambda { |project|
    ids = [project.id]
    for_context_map(TYPE_CONTEXT_PREDICATES.keys.index_with { ids })
  }

  # Org-wide form of the same boundary (S3a T3, plan §9.1): `project_ids_by_type`
  # maps a fragmentable_type to the project ids it may come from — the caller
  # (Retriever#org path) derives that from the asker's per-area reach. Types not
  # in the map, unknown types and empty id sets are excluded entirely
  # (fail-closed). The privacy predicates are the SAME rows as the single-project
  # scope — one owner, two call shapes.
  scope :for_context_map, lambda { |project_ids_by_type|
    clauses = []
    binds = {}
    project_ids_by_type.each do |type, ids|
      predicate = TYPE_CONTEXT_PREDICATES[type]
      next if predicate.nil? || ids.blank?

      bind = :"ctx_#{type.underscore}_ids"
      clauses << format(predicate, bind: bind)
      binds[bind] = ids
    end
    next none if clauses.empty?

    joins(FRAGMENTABLE_PROJECT_JOINS).where(clauses.join(' OR '), **binds)
  }

  # "Has been embedded" for reporting (embedding v2 PR 5): a fragment counts as
  # embedded when it has an INDEXED sidecar row. Replaces `where.not(embedding: nil)`
  # on the inline column — that column is a 1536-only lane since PR 5 (NULL for a
  # non-1536 org, dropped entirely in PR 7), so the old form would report such an org
  # as permanently unembedded although its sidecar is full.
  #
  # DELIBERATELY without a vector-space (triple) filter: the question here is "was
  # this embedded at all?", not "is it readable in the CURRENT space?" — the latter
  # is what Embeddings::SpaceAlignment / `rake embeddings:check_alignment` answers,
  # and mixing the two would turn a status page into a second, weaker gate.
  scope :with_sidecar_embedding, lambda {
    where(ContentEmbedding.where(embeddable_type: 'Fragment', indexed: true)
                          .where('content_embeddings.embeddable_id = fragments.id')
                          .arel.exists)
  }

  # Removes a set of fragmentables' fragments AND the sidecar rows behind them, in the
  # only order that works: the sidecar purge takes a SUBSELECT over the fragment rows, so
  # they have to still exist when it runs (ContentEmbedding.purge_for's contract).
  #
  # ONE owner, because `delete_all` on the fragments is callback-free — Fragment's own
  # `dependent: :delete_all` does NOT fire for it — so every bulk path has to remember to
  # purge the sidecar by hand. That rule was already written out at one call site
  # (Actors::DestroyPost) and the privacy toggle would have been the second copy of it.
  #
  # Callers on a delete path must run this INSIDE their transaction and BEFORE deleting
  # the fragmentables themselves.
  def self.purge_with_embeddings(fragmentable_type:, fragmentable_ids:)
    ids = Array(fragmentable_ids)
    return 0 if ids.empty?

    fragments = where(fragmentable_type: fragmentable_type, fragmentable_id: ids)
    ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: fragments.select(:id))
    fragments.delete_all
  end

  # Full-text search with German dictionary and highlighting
  pg_search_scope :search_full_text_with_highlight_german,
                  against: :plain_text_content,
                  using: {
                    tsearch: {
                      prefix: true,
                      dictionary: 'german',
                      highlight: {
                        StartSel: '<mark>',
                        StopSel: '</mark>',
                        HighlightAll: true,
                        ShortWord: 2,
                        MinWords: 15, # increased for larger excerpts
                        MaxWords: 100, # increased for larger excerpts
                        MaxFragments: 2, # reduced to obtain larger excerpts
                        FragmentDelimiter: ' ... '
                      }
                    }
                  }

  # Full-text search with English dictionary and highlighting
  pg_search_scope :search_full_text_with_highlight_english,
                  against: :plain_text_content,
                  using: {
                    tsearch: {
                      prefix: true,
                      dictionary: 'english',
                      highlight: {
                        StartSel: '<mark>',
                        StopSel: '</mark>',
                        HighlightAll: true,
                        ShortWord: 2,
                        MinWords: 15, # increased for larger excerpts
                        MaxWords: 100, # increased for larger excerpts
                        MaxFragments: 2, # reduced to obtain larger excerpts
                        FragmentDelimiter: ' ... '
                      }
                    }
                  }

  # Optional: basic search without highlighting
  pg_search_scope :search_full_text_german,
                  against: :plain_text_content,
                  using: {
                    tsearch: {
                      prefix: true,
                      dictionary: 'german'
                    }
                  }

  pg_search_scope :search_full_text_english,
                  against: :plain_text_content,
                  using: {
                    tsearch: {
                      prefix: true,
                      dictionary: 'english'
                    }
                  }

  # Custom highlighting for semantic matches
  def custom_highlight(query, language)
    dictionary = language == :german ? 'german' : 'english'

    # Ensure the inputs are safe
    safe_query = self.class.connection.quote(query)
    safe_content = self.class.connection.quote(plain_text_content)

    # SQL query for highlighting
    highlight_sql = <<-SQL
      SELECT ts_headline(
        '#{dictionary}',
        #{safe_content},
        to_tsquery('#{dictionary}', #{safe_query}),
        'StartSel=<mark>, StopSel=</mark>, HighlightAll=true, ShortWord=2, MinWords=15, MaxWords=100, MaxFragments=2, FragmentDelimiter= ... '
      )
    SQL

    # Run the SQL query and return the result
    self.class.connection.select_value(highlight_sql)
  end
end

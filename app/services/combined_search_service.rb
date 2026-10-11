# frozen_string_literal: true

class CombinedSearchService
  # Candidate pool for the semantic search: load only the top (limit × factor)
  # fragments by distance on the DB side, before the Ruby threshold filter runs.
  # Without an SQL LIMIT, ALL accessible fragments of the org would be materialized
  # (each ~12 KB embedding vector) — memory and runtime would grow linearly with
  # the data volume. For normalized embeddings the distance order is identical to
  # the similarity order, so factor 1 would already be lossless; factor 4 is a
  # safety margin for not perfectly normalized vectors (float noise, future
  # embedding providers).
  SEMANTIC_CANDIDATE_POOL_FACTOR = 4

  attr_reader :organisation, :query, :embedding, :fulltext_weight, :semantic_weight, :limit, :similarity_threshold, :project_id, :current_user

  def initialize(organisation:, query:, embedding:, current_user:, fulltext_weight: 0.5, semantic_weight: 0.5, limit: 15, similarity_threshold: 0.81, project_id: nil)
    @organisation          = organisation
    @query                 = query
    @embedding             = embedding
    @current_user          = current_user
    @fulltext_weight       = fulltext_weight
    @semantic_weight       = semantic_weight
    @limit                 = limit
    @similarity_threshold  = similarity_threshold
    @project_id            = project_id
  end

  def call
    # 1. Base query: org scope (defense-in-depth) + restriction to the projects
    #    accessible to the current user (protection against cross-project leaks)
    base_fragment_query = apply_access_filter(
      Fragment.where(organisation: organisation).includes(:fragmentable)
    )

    # 2. Full-text search in both languages
    fulltext_results_german  = base_fragment_query.search_full_text_german(query)
    fulltext_results_english = base_fragment_query.search_full_text_english(query)

    # Combine the full-text results and remove duplicates
    fulltext_results = (fulltext_results_german + fulltext_results_english).uniq

    # 3. Semantic search (only if an embedding is present), through the ONE read seam
    #    over the content_embeddings sidecar (embedding v2 PR 4b).
    #    Euclidean on the DB side, because idx_ce_fragment_1536_l2 is an HNSW index
    #    with vector_l2_ops — cosine ('<=>') would bypass it. That metric now lives in
    #    Embeddings::NearestNeighbors; same convention as PromptBuildingService and
    #    Lalabase::ProjectRag::Retriever#fetch_content. The threshold filter below
    #    still computes cosine similarity in Ruby; for the normalized OpenAI
    #    embeddings the ranking is identical.
    #    `where.not(embedding: nil)` is obsolete: no sidecar row = no join hit.
    semantic_hits = if embedding.present?
                      Embeddings::NearestNeighbors.call(
                        embeddable_type: 'Fragment', organisation: organisation,
                        query_vector: embedding, limit: limit * SEMANTIC_CANDIDATE_POOL_FACTOR,
                        scope: base_fragment_query, with_vectors: true
                      )
                    else
                      []
                    end

    # Cosine similarity ONCE per candidate, from the sidecar vector the hit carries
    # (was: twice, off fragment.embedding — threshold here and scoring below; the
    # inline column disappears in PR 7). Insertion order = distance order, so
    # `first(limit)` still keeps the nearest candidates.
    similarity_by_fragment = semantic_hits.to_h do |hit|
      [hit.record, calculate_cosine_similarity(hit.vector, embedding)]
    end
    semantic_results = similarity_by_fragment
                       .select { |_fragment, similarity| similarity >= similarity_threshold }
                       .keys.first(limit)

    # 3. Collect all unique fragments
    all_fragments = (fulltext_results + semantic_results).uniq

    # 4. Combine scoring - use all fragments as the basis
    combined_scores = {}

    all_fragments.each do |fragment|
      score = 0.0

      # Add full-text score if present
      score += fulltext_weight if fulltext_results.include?(fragment)

      # Add semantic score if present (map lookup — AR hash/eql? are id-based, so a
      # fragment instance from the full-text query finds its semantic similarity).
      score += similarity_by_fragment[fragment] * semantic_weight if semantic_results.include?(fragment)

      combined_scores[fragment] = score
    end

    # 5. Sort by score and cap at the limit
    combined_scores.sort_by { |_, score| -score }.first(limit).map(&:first)
  end

  # Deliberately duplicated in Meetings::TicketSuggestionService#cosine_similarity
  # (Slice 8): that job runs with no current_user and must stay off the Slice-7b
  # search surface, so it keeps a local copy instead of instantiating this service.
  # If a THIRD standalone copy appears, unify the three into one vector-math source.
  def calculate_cosine_similarity(vec_a, vec_b)
    # Check whether both vectors are present
    return 0.0 if vec_a.nil? || vec_b.nil? || vec_a.empty? || vec_b.empty?

    # Make sure both vectors are arrays
    vec_a = vec_a.to_a if vec_a.respond_to?(:to_a)
    vec_b = vec_b.to_a if vec_b.respond_to?(:to_a)

    # Check whether the vectors have the same length
    return 0.0 if vec_a.length != vec_b.length

    dot_product = vec_a.zip(vec_b).sum { |a, b| a * b }
    magnitude_a = Math.sqrt(vec_a.map { |x| x**2 }.sum)
    magnitude_b = Math.sqrt(vec_b.map { |x| x**2 }.sum)

    # Avoid division by zero
    return 0.0 if magnitude_a == 0.0 || magnitude_b == 0.0

    dot_product / (magnitude_a * magnitude_b)
  end

  private

  # Restricts fragments to the projects accessible to current_user and keeps the
  # private-post filter in place. An optionally passed project_id is authorized
  # against the user's actual access (protection against param tampering).
  def apply_access_filter(fragment_query)
    general_ids       = scope_to_requested_project(accessible_project_ids)
    documentation_ids = scope_to_requested_project(documentation_readable_project_ids)
    meeting_ids       = scope_to_requested_project(meetings_readable_project_ids)

    # No access in ANY dimension (or the explicitly requested project is allowed in
    # none) => no matches. This short-circuit covers the "nothing accessible at all"
    # case; the query below stays correct even when only some of the three id sets
    # are populated, because Rails renders an empty array as `IN (NULL)` (valid SQL
    # that matches nothing).
    return fragment_query.none if general_ids.empty? && documentation_ids.empty? && meeting_ids.empty?

    # JOIN centralized in Fragment (shared with ProjectRag::Retriever#fetch_content).
    # The WHERE clause below stays here because its visibility semantics (current_user,
    # multi-project, private posts addressed to the recipient) differ from the
    # content RAG — for details see the Fragment::FRAGMENTABLE_PROJECT_JOINS docs.
    #
    # DocumentationPage is gated on a SEPARATE id set (documentation_ids): its area
    # right documentation_access defaults to no_access, so gating it on plain project
    # visibility (general_ids) would surface doc excerpts to members who cannot browse
    # them (content leak + 403 on click). `removed_at IS NULL` mirrors
    # Fragment#for_project_context (defense-in-depth against a lingering fragment of a
    # soft-removed page).
    #
    # Meeting is likewise gated on its OWN id set (meeting_ids): meetings_access also
    # defaults to no_access, AND a meeting is searchable only on its explicit
    # per-meeting opt-in — hence the extra `create_embeddings = TRUE` (mirrors
    # Fragment#for_project_context; PII fail-closed, plan §7 "Rohtranskript ungewollt
    # auffindbar").
    #
    # MeetingAnalysis (Slice 7b) shares the SAME meeting_ids gate (same :meetings
    # permission — no new id set needed) plus a per-analysis row filter is_private =
    # FALSE AND include_in_search = TRUE (Entscheidung 5). analysis_meetings is the
    # aliased meeting join (Fragment::FRAGMENTABLE_PROJECT_JOINS). This row filter is
    # DELIBERATELY duplicated from Fragment#for_project_context — the WHERE semantics
    # diverge per consumer (see the FRAGMENTABLE_PROJECT_JOINS docs); do NOT unify.
    fragment_query.joins(Fragment::FRAGMENTABLE_PROJECT_JOINS).where(
      "(fragments.fragmentable_type = 'Note' AND notes.project_id IN (:ids)) OR " \
      "(fragments.fragmentable_type = 'Ticket' AND tickets.project_id IN (:ids)) OR " \
      "(fragments.fragmentable_type = 'Post' AND post_tickets.project_id IN (:ids) AND posts.id IN (:readable_post_ids)) OR " \
      "(fragments.fragmentable_type = 'DocumentVersion' AND documents.project_id IN (:ids)) OR " \
      "(fragments.fragmentable_type = 'DocumentationPage' AND documentation_sets.project_id IN (:doc_ids) AND documentation_pages.removed_at IS NULL) OR " \
      "(fragments.fragmentable_type = 'Meeting' AND meetings.project_id IN (:meeting_ids) AND meetings.create_embeddings = TRUE) OR " \
      "(fragments.fragmentable_type = 'MeetingAnalysis' AND analysis_meetings.project_id IN (:meeting_ids) " \
      'AND meeting_analyses.is_private = FALSE AND meeting_analyses.include_in_search = TRUE)',
      ids: general_ids, doc_ids: documentation_ids, meeting_ids: meeting_ids,
      # A relation, so Rails inlines it as a subquery AFTER the named binds are
      # replaced: the rule stays Post.readable_by, and no bind can reach inside it
      readable_post_ids: Post.readable_by(current_user, organisation).select(:id)
    )
  end

  # Applies the optional project_id param to a base list of accessible project ids.
  # An explicitly requested project is authorized against the user's ACTUAL access
  # (protection against param tampering): it survives only if it is in the base list.
  def scope_to_requested_project(project_ids)
    return project_ids if project_id.blank?

    project_ids.include?(project_id) ? [project_id] : []
  end

  # Single source of truth for project visibility: ProjectPolicy::Scope handles
  # org admins (all projects) and global read rights correctly. This is the same source
  # that controllers use via Organisations::ProjectScoping#selectable_projects — called
  # directly here because this service is not a controller (no access to the concern).
  # with_tenant ensures that the admin check runs against the correct organisation
  # (ProjectPolicy::Scope reads the tenant from ActsAsTenant).
  #
  # pluck DELIBERATELY loads the IDs into a Ruby list for the `IN (:ids)` clause; with
  # the realistic per-org project counts here this is uncritical.
  def accessible_project_ids
    @accessible_project_ids ||= if current_user.nil?
                                  []
                                else
                                  ActsAsTenant.with_tenant(organisation) do
                                    ProjectPolicy::Scope.new(current_user, organisation.projects)
                                                        .resolve.pluck(:id)
                                  end
                                end
  end

  # Project ids in which current_user may READ documentation — the :documentation
  # area right, DELIBERATELY distinct from accessible_project_ids (general project
  # visibility). documentation_access defaults to no_access, so a project member
  # without an explicit doc grant must not see doc content in search results. This is
  # the canonical, SQL-based source (admins, org-wide doc roles, per-project grants,
  # minus no_access overrides) — the same :documentation area right that governs
  # browsing via DocumentationSetPolicy. (Search is marginally stricter than that
  # policy in one edge: a global-doc-role holder with an explicit per-project
  # no_access override loses that project here, but keeps it under the policy's
  # scope.all — a safe, no-leak divergence.)
  def documentation_readable_project_ids
    @documentation_readable_project_ids ||= if current_user.nil?
                                              []
                                            else
                                              ActsAsTenant.with_tenant(organisation) do
                                                AccessCheck::ProjectAccessService.accessible_project_ids(
                                                  current_user, organisation, action: :read, area: :documentation
                                                )
                                              end
                                            end
  end

  # Project ids in which current_user may READ meetings — the :meetings area right,
  # DELIBERATELY distinct from accessible_project_ids (general project visibility)
  # AND from documentation_ids. meetings_access defaults to no_access, so a plain
  # project member must not see meeting content in search results. Combined with the
  # per-meeting create_embeddings opt-in in the WHERE clause, this is the fail-closed
  # gate for the PII-heavy transcript/notes (plan §7). Gespräche Slice 6.
  def meetings_readable_project_ids
    @meetings_readable_project_ids ||= if current_user.nil?
                                         []
                                       else
                                         ActsAsTenant.with_tenant(organisation) do
                                           AccessCheck::ProjectAccessService.accessible_project_ids(
                                             current_user, organisation, action: :read, area: :meetings
                                           )
                                         end
                                       end
  end
end

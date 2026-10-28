# frozen_string_literal: true

# app/services/power_search_service.rb

class PowerSearchService
  SIMILARITY_THRESHOLD = 0.81
  SEMANTIC_THRESHOLD = 0.7
  LIMIT = 15

  # Stable keys, not labels: the results view translates them
  # (views.organisations.power_search.power_search_results.types.*).
  RESULT_TYPES = {
    'Note' => :note,
    'DocumentVersion' => :document,
    'DocumentationPage' => :documentation,
    'Post' => :post,
    'Ticket' => :ticket,
    'Meeting' => :meeting,
    'MeetingAnalysis' => :meeting_analysis
  }.freeze

  def initialize(query, organisation, project_id = nil, current_user = nil)
    @query        = query
    @organisation = organisation
    @project_id   = project_id
    @current_user = current_user
  end

  # True when the semantic layer was expected but unavailable (AI off, quota
  # exhausted, or an embedding error) — the search ran full-text only and the UI
  # shows the "ohne KI-Ranking" hint (plan §4.6 states 1/3).
  attr_reader :semantic_degraded
  alias semantic_degraded? semantic_degraded

  def execute
    # Try to generate an embedding, fall back to pure full-text search.
    # AI disabled / quota exhausted are EXPECTED states (not failures): search
    # degrades to full-text without warn-level log noise, and sets the degraded
    # flag so the UI can note the missing semantic ranking.
    @semantic_degraded = false
    question_embedding = begin
      Lalabase::QueryEmbedding.embed(@query, @organisation)
    rescue Lalabase::Llm::QuotaExceededError
      Rails.logger.debug { 'PowerSearchService: AI quota exhausted — full-text search only.' }
      @semantic_degraded = true
      nil
    rescue Lalabase::Llm::AiDisabledError
      Rails.logger.debug { 'PowerSearchService: AI disabled for organisation — full-text search only.' }
      @semantic_degraded = true
      nil
    rescue StandardError => e
      Rails.logger.warn "Embedding generation failed: #{e.message}. Falling back to full-text search only."
      @semantic_degraded = true
      nil
    end

    weights = dynamic_weights(@query)

    # Perform the search with CombinedSearchService
    combined_search = CombinedSearchService.new(
      organisation: @organisation,
      query: @query,
      embedding: question_embedding,
      current_user: @current_user,
      fulltext_weight: weights[:fulltext_weight],
      semantic_weight: weights[:semantic_weight],
      limit: LIMIT,
      similarity_threshold: SIMILARITY_THRESHOLD,
      project_id: @project_id
    )

    results = combined_search.call

    # Similarity vectors for the re-scoring below, ONE batch fetch for all results
    # (embedding v2 PR 5, §3.4.1). Skipped without a question embedding — then every
    # similarity is 0.0 anyway, exactly as before.
    vectors = question_embedding.present? ? sidecar_vectors_for(results) : {}

    # Eager-load fragmentable objects to avoid N+1 queries
    preload_fragmentables(results)

    # Build the highlight map (only for full-text hits)
    highlight_map = highlight_fragments(results, @query)

    # Group fragments by the underlying object (fragmentable)
    grouped_by_object = results.group_by do |fragment|
      [fragment.fragmentable_type, fragment.fragmentable_id]
    end

    # Process each group and combine the information
    processed_results = grouped_by_object.filter_map do |_object_key, fragments|
      # Skip fragments without a valid fragmentable object
      fragments = fragments.select { |f| f.fragmentable.present? }
      next if fragments.empty?

      # Compute similarity once per fragment (avoids redundant computation)
      similarities = fragments.to_h do |fragment|
        [fragment.id, combined_search.calculate_cosine_similarity(vectors[fragment.id], question_embedding)]
      end

      best_fragment = fragments.max_by { |f| similarities[f.id] }
      similarity = similarities[best_fragment.id]

      all_highlights = fragments.map { |f| highlight_map[f.id] }.compact
      highlighted_content = all_highlights.first || highlight_map[best_fragment.id]

      match_types = determine_match_types(fragments, highlight_map, similarities)

      build_result(best_fragment, similarity, highlighted_content, match_types)
    end

    # Sort by similarity
    processed_results.sort_by! { |result| -result[:similarity] }

    processed_results
  end

  private

  # Similarity vectors for the result fragments, from the SIDECAR (embedding v2
  # PR 5, §3.4.1). The inline fragments.embedding column this used to read is a
  # 1536-only lane since PR 5 (NULL for a non-1536 org, dropped entirely in PR 7),
  # so reading it made the ranking of such an org silently collapse to 0.0 — the
  # search degraded to full-text without any error, and the alignment gate cannot
  # see it (the sidecar rows are perfectly fine). Same space resolution as the read
  # seam; a fragment without a row in the current space scores 0.0, which is the
  # SAME fail-soft behaviour as before (e.g. mid-reindex).
  #
  # WHY an id lookup lives here, next to Embeddings::NearestNeighbors rather than
  # inside it: this is not a vector SEARCH but a re-scoring of an already decided
  # result set, and it must cover the FULL-TEXT-only hits too — CombinedSearchService
  # computes the same similarity internally (from the same sidecar), but only for its
  # semantic candidates. Handing that map out instead would drop full-text-only hits
  # to 0.0, a real behaviour change. To be re-evaluated together with
  # CombinedSearchService in PR 7, when the inline columns go.
  # Rescued like every other AI-touching step of #execute: search is a core feature
  # and must not 500 because a credential was deactivated between the query
  # embedding and this lookup. Degrades to 0.0 similarities (full-text ranking) —
  # the same fail-soft the callers below already expect from a missing vector.
  def sidecar_vectors_for(fragments)
    return {} if fragments.empty?

    # :active — the SAME space the query embedding came from (#execute above). Having
    # both resolutions in one class is exactly why they must not drift: a similarity
    # between a target-space vector and an active-space query would be a meaningless
    # number, not an error.
    space = Lalabase::Llm::Factory.embedding_space_for(@organisation, space: :active)
    ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragments.map(&:id),
                           organisation_id: @organisation.id, indexed: true, **space)
                    .pluck(:embeddable_id, :embedding).to_h
  rescue StandardError => e
    Rails.logger.warn "PowerSearchService: sidecar vector lookup failed (#{e.class}: #{e.message}). " \
                      'Falling back to full-text ranking.'
    @semantic_degraded = true
    {}
  end

  def preload_fragmentables(fragments)
    ActiveRecord::Associations::Preloader.new(
      records: fragments,
      associations: [:fragmentable]
    ).call

    grouped = fragments.group_by(&:fragmentable_type)
    grouped.each do |type, frags|
      klass = type.safe_constantize
      next unless klass

      records = frags.filter_map(&:fragmentable)
      next if records.empty?

      nested = []
      nested << :project if klass.reflect_on_association(:project)
      nested << { ticket: :project } if klass.reflect_on_association(:ticket)
      nested << { document: :project } if klass.reflect_on_association(:document)
      nested << { documentation_set: :project } if klass.reflect_on_association(:documentation_set)
      # MeetingAnalysis (Slice 7b) reaches its project via the meeting — preload both so
      # result_project/result_link avoid an N+1 (it has no direct :project association).
      nested << { meeting: :project } if klass.reflect_on_association(:meeting)
      nested << :rich_text_content if klass.reflect_on_association(:rich_text_content)

      next unless nested.any?

      ActiveRecord::Associations::Preloader.new(
        records: records,
        associations: nested
      ).call
    end
  end

  def highlight_fragments(fragments, query)
    # Full-text search with highlighting for German
    highlighted_german  = Fragment.search_full_text_with_highlight_german(query)
                                  .with_pg_search_highlight
                                  .where(id: fragments.map(&:id))

    # Full-text search with highlighting for English
    highlighted_english = Fragment.search_full_text_with_highlight_english(query)
                                  .with_pg_search_highlight
                                  .where(id: fragments.map(&:id))

    # Combine the highlighted results and remove duplicates
    combined_highlighted = (highlighted_german + highlighted_english).uniq

    # Map fragment.id => marked text
    combined_highlighted.to_h { |frag| [frag.id, frag.pg_search_highlight] }
  end

  def dynamic_weights(query)
    if query.include?(' ')
      { fulltext_weight: 0.4, semantic_weight: 0.6 }
    else
      { fulltext_weight: 0.7, semantic_weight: 0.3 }
    end
  end

  def build_result(result, similarity, highlighted_content, match_types)
    project = result_project(result)
    {
      type: result_type(result.fragmentable_type),
      title: result_title(result),
      link: result_link(result),
      project_name: project&.name,
      project_link: project && Rails.application.routes.url_helpers.organisation_project_path(@organisation, project),
      date: result_date(result),
      content: result_content(result),
      highlighted_content: highlighted_content,
      similarity: similarity,
      match_types: match_types,
      highlight: highlighted_content
    }
  end

  def result_type(fragmentable_type)
    RESULT_TYPES.fetch(fragmentable_type, :unknown)
  end

  # When the information came into being, the date the results show next to the
  # type. A meeting counts from the day it took place, not from the day somebody
  # entered it; everything else from its creation. Not updated_at: a status change
  # would make an old ticket look fresh.
  def result_date(result)
    record = result.fragmentable
    return unless record

    result.fragmentable_type == 'Meeting' ? record.occurred_at : record.created_at
  end

  def result_title(result)
    case result.fragmentable_type
    when 'Note'
      result.fragmentable&.title || deleted_title(:note)
    when 'DocumentVersion'
      result.fragmentable&.document&.title || deleted_title(:document)
    when 'DocumentationPage'
      page = result.fragmentable
      page&.title.presence || page&.path || deleted_title(:documentation)
    when 'Post'
      result.fragmentable&.ticket&.title || deleted_title(:ticket)
    when 'Ticket'
      result.fragmentable&.title || deleted_title(:ticket)
    when 'Meeting'
      result.fragmentable&.title || deleted_title(:meeting)
    when 'MeetingAnalysis'
      result.fragmentable&.prompt_title || deleted_title(:meeting_analysis)
    else
      deleted_title(:unknown)
    end
  end

  def deleted_title(type)
    I18n.t("services.power_search.deleted_titles.#{type}")
  end

  def result_project(result)
    case result.fragmentable_type
    when 'Note', 'Ticket', 'Meeting'
      result.fragmentable&.project
    when 'DocumentVersion'
      result.fragmentable&.document&.project
    when 'DocumentationPage'
      result.fragmentable&.documentation_set&.project
    when 'Post'
      result.fragmentable&.ticket&.project
    when 'MeetingAnalysis'
      # An analysis carries the project via its meeting (no direct :project assoc).
      result.fragmentable&.meeting&.project
    end
  end

  def determine_match_types(fragments, highlight_map, similarities)
    match_types = []
    match_types << :fulltext if fragments.any? { |f| highlight_map[f.id].present? }
    match_types << :semantic if fragments.any? { |f| similarities[f.id] >= SEMANTIC_THRESHOLD }
    match_types << :unknown if match_types.empty?
    match_types
  end

  def result_link(result)
    helpers = Rails.application.routes.url_helpers
    case result.fragmentable_type
    when 'Note'
      note = result.fragmentable
      return '#' unless note.project

      helpers.organisation_project_notes_path(@organisation, note.project, note_id: note.id)
    when 'DocumentVersion'
      doc = result.fragmentable.document
      return '#' unless doc&.project

      helpers.organisation_project_document_path(@organisation, doc.project, doc)
    when 'DocumentationPage'
      page = result.fragmentable
      set = page&.documentation_set
      return '#' unless set&.project

      # Deep-link to the exact page — same set_id + page(path) params the local
      # documentation tree uses (documentation#index, collection route).
      helpers.organisation_project_documentation_index_path(@organisation, set.project, set_id: set.id, page: page.path)
    when 'Post'
      ticket = result.fragmentable.ticket
      return '#' unless ticket&.project

      helpers.organisation_project_ticket_path(@organisation, ticket.project, ticket)
    when 'Ticket'
      ticket = result.fragmentable
      return '#' unless ticket.project

      helpers.organisation_project_ticket_path(@organisation, ticket.project, ticket)
    when 'Meeting'
      # The meeting show route renders the master-detail with this meeting
      # selected (Gespräche Slice 6) — same deep-link the chat citation uses.
      meeting = result.fragmentable
      return '#' unless meeting.project

      helpers.organisation_project_meeting_path(@organisation, meeting.project, meeting)
    when 'MeetingAnalysis'
      # An analysis has no own page (Slice 7b) → deep-link to its meeting, same as the
      # chat citation. project comes via the meeting.
      analysis = result.fragmentable
      meeting = analysis.meeting
      return '#' unless meeting&.project

      helpers.organisation_project_meeting_path(@organisation, meeting.project, meeting)
    else
      '#'
    end
  end

  def result_content(result)
    case result.fragmentable_type
    when 'Note', 'Ticket', 'DocumentVersion', 'DocumentationPage', 'Meeting', 'MeetingAnalysis'
      result.fragmentable.plain_text_version
    when 'Post'
      result.fragmentable.content
    else
      ''
    end
  end
end

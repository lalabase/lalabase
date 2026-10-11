# frozen_string_literal: true

# Query object for the comprehensive ticket search
# Supports:
# - SmartFolder filtering
# - Full-text search with three modes (title_only, content, full)
# - Weighted relevance ordering
# - Additional filters (status, priority, tags, etc.)
class TicketSearchQuery
  class SmartFolderNotFoundError < StandardError; end

  include SortableQuery

  # Define the search modes
  SEARCH_MODES = {
    'title_only' => :title_only,           # Title only
    'content' => :content,                 # Title + content + posts
    'full' => :full                        # Title + content + posts + files
  }.freeze

  # Weights for ranking
  SEARCH_WEIGHTS = {
    ticket_title: 4.0,      # Highest priority
    ticket_content: 2.0,    # Medium priority
    post_content: 1.0,      # Lower priority
    file_content: 0.5       # Lowest priority
  }.freeze

  # The joined texts of the content and full modes
  TICKET_TEXT_JOIN = 'LEFT JOIN action_text_rich_texts ticket_texts ON ticket_texts.record_id = tickets.id ' \
                     "AND ticket_texts.record_type = 'Ticket' AND ticket_texts.name = 'content'"
  POST_TEXT_JOIN = 'LEFT JOIN action_text_rich_texts post_texts ON post_texts.record_id = posts.id ' \
                   "AND post_texts.record_type = 'Post' AND post_texts.name = 'content'"
  POST_DOCUMENTS_JOIN = 'LEFT JOIN post_documents ON post_documents.post_id = posts.id'

  # The derived table that carries the hits of a ranked search and their rank
  HITS_TABLE = 'ticket_search_hits'

  def initialize(project, params = {}, options = {})
    @project = project
    @params = params
    @current_user = options[:current_user]
    @policy_scope = options[:policy_scope]
  end

  def call
    @query = build_base_query
    @query = apply_smart_folder_filter(@query)
    @query = apply_search_based_on_mode(@query)
    @query = apply_additional_filters(@query)
    @query = apply_sorting(@query)
    @query
  end

  delegate :explain, to: :call

  private

  def build_base_query
    @project.tickets
            .includes(
              :creator,
              :tags,
              :assignees,
              :ticket_assignments,
              :rich_text_content,
              { ticket_assignments: :user }
            )
  end

  def apply_smart_folder_filter(query)
    return query unless smart_folder_id.present?

    begin
      smart_folder = @policy_scope.find(smart_folder_id)

      return query unless smart_folder.target_object_type.in?(%w[Ticket All])

      return query.none unless smart_folder.accessible_by?(@current_user)

      SmartFolderQueryBuilder.new(smart_folder, @current_user).filter_relation(query)
    rescue ActiveRecord::RecordNotFound
      raise SmartFolderNotFoundError, "Smart Folder #{smart_folder_id} wurde nicht gefunden"
    end
  end

  def apply_search_based_on_mode(query)
    return query unless search_term.present?

    # Hybrid approach: short terms with ILIKE, longer ones with FTS
    if search_term.length < 3
      apply_simple_ilike_search(query)
    else
      case search_mode
      when :title_only
        apply_title_only_search(query)
      when :content
        apply_content_search(query)
      when :full
        apply_full_search(query)
      else
        apply_content_search(query) # Default: content
      end
    end
  end

  # Every search narrows the scope it is handed and never rebuilds it. The hits
  # are an id subquery (short terms) or a joined subquery with one row per
  # ticket and its rank (long terms). Neither GROUP BY nor DISTINCT reaches the
  # list's relation, so counting, sorting and the board work on it as on any
  # ticket scope. Until 01.10.2026 each mode built a grouped or DISTINCT
  # relation of its own with a hand-made #count: the hit count ignored every
  # later filter, the board got a Hash, and a short search sorted by status
  # failed in Postgres (spec/requests/organisations/tickets_search_counts_spec.rb).

  # Simple ILIKE search for short terms (< 3 characters), unranked
  def apply_simple_ilike_search(query)
    hits = search_candidates(query)
    hits = if search_mode == :title_only
             hits.where('LOWER(tickets.title) ILIKE LOWER(:search)', search: "%#{search_term}%")
           else
             conditions = content_columns.map { |column| "LOWER(#{column}) ILIKE LOWER(:search)" }
             hits.joins(*content_joins).where(conditions.join(' OR '), search: "%#{search_term}%")
           end

    query.where(id: hits.select(:id)).reorder('tickets.created_at DESC')
  end

  # Mode 1: Title-only search
  def apply_title_only_search(query)
    fts_query = build_fts_query_with_prefix

    apply_ranked_search(query,
                        condition: "to_tsvector('german', tickets.title) @@ #{fts_query}",
                        rank: "ts_rank(to_tsvector('german', tickets.title), #{fts_query}, 1)")
  end

  # Mode 2: Title + content + posts
  def apply_content_search(query)
    apply_ranked_search(query, joins: content_joins,
                               condition: build_content_search_condition,
                               rank: build_content_rank_expression_grouped)
  end

  # Mode 3: Full search including files
  def apply_full_search(query)
    apply_ranked_search(query, joins: content_joins,
                               condition: build_full_search_condition,
                               rank: build_full_rank_expression_grouped)
  end

  # Joins the hits with their rank to the scope. GROUP BY stays inside the
  # subquery: a ticket with several matching comments or files is one hit.
  def apply_ranked_search(query, condition:, rank:, joins: [])
    tickets = Ticket.arel_table
    # rank and condition embed the term as a quoted literal (build_fts_query_with_prefix):
    # no named binds may join them.
    rank_column = Arel::Nodes::As.new(Arel::Nodes::Grouping.new(Arel.sql(rank)), Arel.sql('search_rank'))

    hits = search_candidates(query)
    hits = hits.joins(*joins) if joins.any?
    hits = hits.where(condition).group(tickets[:id]).select(tickets[:id].as('ticket_id'), rank_column)

    hits_table = Arel::Table.new(HITS_TABLE)
    join = tickets.join(hits.arel.as(HITS_TABLE)).on(hits_table[:ticket_id].eq(tickets[:id])).join_sources

    query.joins(join).reorder(Arel.sql("#{HITS_TABLE}.search_rank DESC NULLS LAST, tickets.created_at DESC"))
  end

  # The tickets a search looks at: those of the scope it was handed.
  def search_candidates(query)
    Ticket.where(id: query.select(:id))
  end

  # The joins of the content and full modes. Comments join through the readable
  # ones only (readable_posts_join), their texts and files through those.
  def content_joins
    joins = [TICKET_TEXT_JOIN, readable_posts_join, POST_TEXT_JOIN]
    joins << POST_DOCUMENTS_JOIN if search_mode == :full
    joins
  end

  # The texts a short search compares in the content and full modes.
  def content_columns
    columns = ['tickets.title', "COALESCE(ticket_texts.body, '')", "COALESCE(post_texts.body, '')"]
    columns << "COALESCE(post_documents.plain_text_version, '')" if search_mode == :full
    columns
  end

  # Search conditions for content mode
  def build_content_search_condition
    # Build FTS query with prefix matching
    fts_query = build_fts_query_with_prefix

    conditions = [
      "to_tsvector('german', tickets.title) @@ #{fts_query}",
      "to_tsvector('german', COALESCE(ticket_texts.body, '')) @@ #{fts_query}",
      "to_tsvector('german', COALESCE(post_texts.body, '')) @@ #{fts_query}"
    ]

    "(#{conditions.join(' OR ')})"
  end

  # Search conditions for full mode
  def build_full_search_condition
    # Build FTS query with prefix matching
    fts_query = build_fts_query_with_prefix

    conditions = [
      "to_tsvector('german', tickets.title) @@ #{fts_query}",
      "to_tsvector('german', COALESCE(ticket_texts.body, '')) @@ #{fts_query}",
      "to_tsvector('german', COALESCE(post_texts.body, '')) @@ #{fts_query}",
      "to_tsvector('german', COALESCE(post_documents.plain_text_version, '')) @@ #{fts_query}"
    ]

    "(#{conditions.join(' OR ')})"
  end

  # The comment join of every search mode. Only comments the viewer may read
  # (Post.readable_by) join, so the text of a private comment and of its
  # attachments (post_documents joins through it) cannot match for anyone else.
  # Without a viewer, public comments only.
  def readable_posts_join
    readable_ids = Post.readable_by(@current_user, @project.organisation).select(:id).to_sql
    "LEFT JOIN posts ON posts.ticket_id = tickets.id AND posts.id IN (#{readable_ids})"
  end

  # Builds an FTS query with prefix-matching support.
  # The result embeds the user's term as a quoted literal. Never pass a string that
  # contains it to `where` together with named binds: Rails substitutes `:name`
  # tokens inside quoted literals too, and a term containing ":search" then broke
  # out of the literal (SQL injection, fixed 26.09.2026, guard in the query spec).
  def build_fts_query_with_prefix
    # Use to_tsquery with :* for prefix matching
    # Split the terms and append :* for the prefix search
    terms = search_term.split(/\s+/).map { |term| "#{term}:*" }.join(' & ')
    escaped_terms = ActiveRecord::Base.connection.quote(terms)

    "to_tsquery('german', #{escaped_terms})"
  end

  # Ranking for content mode with GROUP BY — MAX() for fields from JOINed tables
  def build_content_rank_expression_grouped
    fts_query = build_fts_query_with_prefix

    expressions = [
      "ts_rank(to_tsvector('german', tickets.title),
               #{fts_query}, 1) * #{SEARCH_WEIGHTS[:ticket_title]}",
      "MAX(ts_rank(to_tsvector('german', COALESCE(ticket_texts.body, '')),
               #{fts_query}, 1)) * #{SEARCH_WEIGHTS[:ticket_content]}",
      "MAX(ts_rank(to_tsvector('german', COALESCE(post_texts.body, '')),
               #{fts_query}, 1)) * #{SEARCH_WEIGHTS[:post_content]}"
    ]

    "GREATEST(#{expressions.join(', ')})"
  end

  # Ranking for full mode with GROUP BY — MAX() for fields from JOINed tables
  def build_full_rank_expression_grouped
    fts_query = build_fts_query_with_prefix

    expressions = [
      "ts_rank(to_tsvector('german', tickets.title),
               #{fts_query}, 1) * #{SEARCH_WEIGHTS[:ticket_title]}",
      "MAX(ts_rank(to_tsvector('german', COALESCE(ticket_texts.body, '')),
               #{fts_query}, 1)) * #{SEARCH_WEIGHTS[:ticket_content]}",
      "MAX(ts_rank(to_tsvector('german', COALESCE(post_texts.body, '')),
               #{fts_query}, 1)) * #{SEARCH_WEIGHTS[:post_content]}",
      "MAX(ts_rank(to_tsvector('german', COALESCE(post_documents.plain_text_version, '')),
               #{fts_query}, 1)) * #{SEARCH_WEIGHTS[:file_content]}"
    ]

    "GREATEST(#{expressions.join(', ')})"
  end

  def apply_additional_filters(query)
    query = apply_tag_filter(query)
    query = apply_date_range_filter(query)
    apply_assignee_filter(query)
  end

  def apply_tag_filter(query)
    return query unless @params[:tag_ids].present?

    tag_ids = Array(@params[:tag_ids]).reject(&:blank?)
    return query if tag_ids.empty?

    query.where(id: Tagging.where(tag_id: tag_ids, taggable_type: 'Ticket').select(:taggable_id))
  end

  def apply_date_range_filter(query)
    query = query.where('tickets.created_at >= ?', @params[:date_from]) if @params[:date_from].present?
    query = query.where('tickets.created_at <= ?', @params[:date_to]) if @params[:date_to].present?
    query
  end

  def apply_assignee_filter(query)
    return query unless @params[:assignee_id].present?

    query.joins(:assignees).where(ticket_assignments: { user_id: @params[:assignee_id] })
  end

  # Helper methods
  def search_term
    @search_term ||= @params[:search]&.strip
  end

  def search_mode
    @search_mode ||= SEARCH_MODES[@params[:search_mode]] || :content
  end

  def smart_folder_id
    @params[:smart_folder_id]
  end
end

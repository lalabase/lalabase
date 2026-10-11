# frozen_string_literal: true

# Read model for the AI sync status page (Organisations::AiSyncStatusesController): the
# organisation's embedding index per project and per content type, plus the fragment
# statistics at the foot of the page.
#
# Entry point: call
#
# Which types exist and what "supposed to be embedded" means per type comes from
# Embeddings::ContentTypes — this service adds the per-project breakdown and nothing
# about the list. It used to keep a private list of four types (and counted fragments of
# a type that does not exist), so the page hid five of nine backlogs; the parity guard
# in spec/services/embeddings/index_health_pending_parity_spec.rb now proves the rows
# here DERIVE from the registry.
#
# "Fragment has an embedding" is answered by Fragment.with_sidecar_embedding since
# embedding v2 PR 5 — see the scope for why the inline column can no longer answer it
# and why the check deliberately carries no vector-space filter.
#
# Never called from the AI hub: it walks every project × every type, and the hub's
# budget is nine queries for the whole page (Embeddings::IndexHealth is the hub's reader).
class AiSyncStatusService
  # The seven figures of one (project, type) cell. Listed once so a type row, a project's
  # totals and the organisation overview are sums over the SAME keys.
  STAT_KEYS = %i[total embeddings_enabled embeddings_processed pending_embeddings with_errors
                 fragments_count fragments_with_embeddings].freeze
  EMPTY_STATS = STAT_KEYS.index_with(0).freeze

  def self.call(organisation:)
    new(organisation: organisation).call
  end

  def initialize(organisation:)
    @organisation = organisation
  end

  def call
    ActsAsTenant.with_tenant(@organisation) do
      projects = project_statistics
      {
        overview: overview(projects),
        projects: projects,
        fragments: fragment_statistics
      }
    end
  end

  private

  # The organisation-wide tiles are the SUM of the per-project rows, not a second count:
  # every registered type hangs off a project through NOT NULL keys, and
  # Organisation#projects carries no default scope (archived ones included), so the sum
  # IS the organisation. That makes the four content tiles free, and it keeps ONE rule on
  # this page — the summary above reads Embeddings::IndexHealth, and the parity guard
  # pins that these sums agree with it for every registered type.
  def overview(projects)
    totals = sum_stats(projects.map { |row| row[:totals] })
    {
      total_content: totals[:total],
      with_embeddings: totals[:embeddings_enabled],
      pending_embeddings: totals[:pending_embeddings],
      embedding_errors: totals[:with_errors],
      total_fragments: Fragment.count,
      fragments_with_embeddings: Fragment.with_sidecar_embedding.count
    }
  end

  # @return [Array<Hash>] one row per project: { project:, by_type: { key => stats },
  #   totals: }, with by_type in registry order.
  def project_statistics
    projects = @organisation.projects.to_a
    return [] if projects.empty?

    by_type = Embeddings::ContentTypes.entries.to_h { |entry| [entry.key, stats_by_project(entry)] }

    projects.map do |project|
      stats = by_type.transform_values { |per_project| per_project.fetch(project.id, EMPTY_STATS) }
      { project: project, by_type: stats, totals: sum_stats(stats.values) }
    end
  end

  def sum_stats(rows)
    STAT_KEYS.index_with { |key| rows.sum { |row| row[key] } }
  end

  # One type, every project at once: one grouped query for the content columns and two
  # for the fragments — three per type instead of seven, and none per project.
  # @return [Hash{String => Hash}] project_id → the seven figures
  def stats_by_project(entry)
    content = content_counts_by_project(entry)
    fragments = fragment_counts_by_project(entry)
    embedded = fragment_counts_by_project(entry, embedded_only: true)

    (content.keys | fragments.keys).index_with do |project_id|
      row = content[project_id] || {}
      {
        total: row['total'].to_i,
        embeddings_enabled: row['enabled'].to_i,
        embeddings_processed: row['processed'].to_i,
        pending_embeddings: row['pending'].to_i,
        with_errors: row['failed'].to_i,
        fragments_count: fragments[project_id] || 0,
        fragments_with_embeddings: embedded[project_id] || 0
      }
    end
  end

  # Raw SQL, the same way and for the same reason as Embeddings::IndexHealth: the FILTER
  # counts have no ActiveRecord form. So acts_as_tenant is NOT in play here and the
  # organisation is bound by hand — the one thing to keep right in this method (the
  # cross-organisation example in the service spec holds it, for every registered type).
  #
  # pending and failed split the way the summary at the top of the page splits them: a
  # record whose last attempt failed is FAILED, not outstanding, and both only count
  # records that are supposed to be embedded. The reprocess button still retries a
  # failed one (Embeddings::PendingEmbeddings has no error term); that difference is
  # deliberate and pinned in the parity spec.
  def content_counts_by_project(entry)
    table = entry.table
    opt_in = "(#{entry.opt_in})"
    pending = Embeddings::ContentTypes.flag_pending(table)
    processed = Embeddings::ContentTypes.processed(table)
    failed = Embeddings::ContentTypes.failed(table)
    sql = <<~SQL.squish
      SELECT #{entry.project_column} AS project_id,
             COUNT(*) AS total,
             COUNT(*) FILTER (WHERE #{opt_in}) AS enabled,
             COUNT(*) FILTER (WHERE #{opt_in} AND #{processed}) AS processed,
             COUNT(*) FILTER (WHERE #{opt_in} AND #{pending} AND NOT #{failed}) AS pending,
             COUNT(*) FILTER (WHERE #{opt_in} AND #{failed}) AS failed
      FROM #{table} #{entry.join} #{entry.project_join}
      WHERE #{table}.organisation_id = ?
      GROUP BY #{entry.project_column}
    SQL
    rows = ActiveRecord::Base.connection.select_all(ActiveRecord::Base.sanitize_sql_array([sql, @organisation.id]))
    rows.to_a.index_by { |row| row['project_id'] }
  end

  # Fragments reach their project through their owner row, using the registry's joins,
  # so a type's fragments land in the same project column its content does. For a
  # document that means the CURRENT version's fragments (the always-on join): the page
  # asks whether current content is embedded, and the org-wide "by type" figures at the
  # foot still count every fragment.
  #
  # ActiveRecord here on purpose, not the raw form above: "has an embedding" is the
  # sidecar rule owned by Fragment.with_sidecar_embedding, and spelling it out as SQL
  # would be a second copy of exactly the kind this service was just cured of.
  def fragment_counts_by_project(entry, embedded_only: false)
    scope = Fragment.where(fragmentable_type: entry.model_name).joins(entry.fragment_join)
    scope = scope.joins(entry.join) if entry.join
    scope = scope.joins(entry.project_join) if entry.project_join
    scope = scope.with_sidecar_embedding if embedded_only
    scope.group(entry.project_column).count
  end

  def fragment_statistics
    recent = Fragment.order(created_at: :desc).limit(10).to_a
    {
      by_type: Fragment.group(:fragmentable_type).count,
      with_embeddings_by_type: Fragment.with_sidecar_embedding.group(:fragmentable_type).count,
      recent_fragments: recent,
      # Which of those actually have an embedding — precomputed here because the view
      # can no longer ask fragment.embedding (1536-only inline lane since embedding v2
      # PR 5, gone with PR 7). Without this the page would contradict ITSELF for a
      # non-1536 org: the counters above report "embedded" from the sidecar while the
      # list below marks every row as missing. One extra query, not an EXISTS per row.
      recent_fragment_ids_with_embedding: Fragment.with_sidecar_embedding.where(id: recent.map(&:id)).ids.to_set
    }
  end
end

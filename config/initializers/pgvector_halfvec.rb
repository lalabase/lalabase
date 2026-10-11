# frozen_string_literal: true

# Embedding v2 PR 5b (doc/embedding_v2_pr5b_halfvec_plan.md §6.3): boot warning when an
# organisation is configured for 3072-dimensional embeddings but the installed pgvector
# cannot index them.
#
# WHY a boot check exists here at all, when PR 5 deliberately decided against one: PR 5's
# fork 6 rejected it because 768/1024 raise no version requirement, and deferred the
# question verbatim to "PR 5b, with a concrete cause". The cause is now real and it is
# qualitatively different from a slow query — below pgvector 0.7.0 `halfvec` does not
# exist, so idx_ce_fragment_3072_l2 and its CodeSymbol twin CANNOT BE CREATED. Retrieval
# then silently falls back to exact scans over every row of that org: correct results,
# quietly unusable performance, and nothing anywhere says why.
#
# Deliberately NARROW: it fires only when an org actually sits on 3072. A blanket warning
# on every pre-0.7 installation would be noise for everyone who never touches 3072, and
# noise is what trains people to ignore warnings. It does not replace the documented
# requirement (self-hosting docs, 01-getting-started/02-requirements) — it catches the
# case where nobody read it.
#
# Follows config/initializers/database_compatibility.rb: after_initialize, server/console
# only (never during asset precompile or rake), and a blanket rescue — a diagnostic must
# never be the reason an app fails to boot.
Rails.application.config.after_initialize do
  # Gate on what must be EXCLUDED, not on what is included. The obvious
  # `defined?(Rails::Server)` (the shape database_compatibility.rb uses) is INERT in
  # production: this app boots via `bundle exec puma -C config/puma.rb` (Procfile), where
  # neither Rails::Server nor Rails::Console is ever defined. The warning would then show
  # up only under `rails s` / `rails c` — precisely not where an operator needs it, while
  # the BYOK docs promise a warning "on boot".
  #
  # Excluded instead: rake / rails-command runs (db:migrate, assets:precompile), where the
  # database may not exist yet and the line would be noise.
  next if defined?(Rake) && Rake.application.top_level_tasks.any?

  begin
    min_version = '0.7.0'
    # Asks the SAME source the query object and the index guard read, instead of
    # re-deriving "> 2000" here — that threshold would be a third copy of a pgvector
    # implementation detail, and the one place it may live is INDEX_CAST_TYPE.
    # INSIDE the begin on purpose: this file promises never to be the reason a boot
    # fails, and a NameError on the constant would break exactly that promise.
    halfvec_dims = Embeddings::NearestNeighbors::INDEX_CAST_TYPE
                   .select { |_dims, cast| cast == 'halfvec' }.keys
    next if halfvec_dims.empty?

    connection = ActiveRecord::Base.connection
    next unless connection.table_exists?('organisations')

    affected = Organisation.where(embedding_dims: halfvec_dims).count
    next if affected.zero?

    installed = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
    # No vector extension at all is a different (louder) problem and not this check's job.
    next if installed.blank?
    next if Gem::Version.new(installed) >= Gem::Version.new(min_version)

    Rails.logger.warn(
      "⚠️  pgvector #{installed} is installed, but #{affected} organisation(s) are configured for " \
      "#{halfvec_dims.join('/')}-dimensional embeddings. Those dimensions are indexed via a " \
      "halfvec cast, which needs pgvector >= #{min_version}. Semantic search for those " \
      'organisations does not merely get slower — it RAISES (PG::UndefinedObject: type "halfvec" ' \
      'does not exist), because the query spells the same cast the index would use. ' \
      'Upgrade the extension (ALTER EXTENSION vector UPDATE) and re-run db:migrate, or move those ' \
      'organisations back to <= 1536 and reindex.'
    )
  rescue StandardError => e
    # Never block boot over a diagnostic (mirrors database_compatibility.rb).
    Rails.logger.error("pgvector halfvec check skipped: #{e.message}")
  end
end

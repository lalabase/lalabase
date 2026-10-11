# frozen_string_literal: true

require 'rails_helper'

# Guard: the app/services entry-point convention (see CLAUDE.md "Service-Konvention"
# and the directory map app/services/CLAUDE.md).
#
# Every NEW file under app/services/ (i.e. not on the legacy allowlist below) must:
#   1. expose `Klass.call` as its public entry point (`def self.call` or
#      `class << self` + `def call`), OR declare its entry point explicitly in the
#      file header via `# Entry point: <method>` — the escape hatch for read/query
#      objects with domain verbs (#can?, #fetch_results, ...),
#   2. use keyword arguments (or no arguments) in #initialize — no positional params,
#   3. carry at least one explanatory comment line above the first class/module
#      definition (magic comments like frozen_string_literal do not count).
#
# Subtrees with their own enforced contracts are excluded:
#   - app/services/actors/**         -> actor_contract_guard_spec.rb
#   - app/services/lalabase/tools/** -> Tools registry contract (self.execute(args:, context:))
#
# Legacy files are allowlisted. Boy-scout rule (CLAUDE.md): whoever substantially
# changes an allowlisted file migrates it to the convention and removes it from the
# list. A legacy file that already satisfies all three rules must be removed from
# the list too (the guard fails otherwise), so the list can only shrink.
#
# The three source-pattern detectors are extracted into ServiceConventionDetectors
# and unit-tested against synthetic input below, so a bypass cannot silently slip
# through a too-narrow regex.
module ServiceConventionDetectors
  EXCLUDED_SUBTREES = %w[
    app/services/actors/
    app/services/lalabase/tools/
  ].freeze

  # Legacy files predating the convention (generated 2026-07-13). Shrink-only:
  # remove an entry when you migrate the file — or when it already complies.
  LEGACY_ALLOWLIST = %w[
    app/services/access_check/org_access_matrix.rb
    app/services/access_check/project_access_service.rb
    app/services/access_check/project_member_access_resolver.rb
    app/services/access_check/project_team_members.rb
    app/services/access_check/role_project_rights_service.rb
    app/services/ad_hoc_filter_service.rb
    app/services/bulk_customer_description_generator.rb
    app/services/changelog/entry_loader.rb
    app/services/codebase_import/custom_attribute_import_service.rb
    app/services/codebase_import/custom_attribute_mapping_resolver.rb
    app/services/codebase_import/mapping_converter.rb
    app/services/codebase_import/tag_import_result.rb
    app/services/codebase_import/tag_import_service.rb
    app/services/codebase_import/ticket_creator.rb
    app/services/codebase_import/ticket_importer.rb
    app/services/codebase_import/ticket_update_importer.rb
    app/services/codebase_import/time_session_importer.rb
    app/services/codebase_import/upload_assignment_service.rb
    app/services/codebase_import/user_matcher.rb
    app/services/combined_search_service.rb
    app/services/customer_description_generator.rb
    app/services/dashboard/briefing_activity_group.rb
    app/services/dashboard/cockpit_rows.rb
    app/services/dashboard/cross_org_action_summary.rb
    app/services/dashboard/daily_briefing.rb
    app/services/dashboard/personal_task_rollup.rb
    app/services/delete_account_service.rb
    app/services/docs/contextual_help.rb
    app/services/docs/help_link_rewriter.rb
    app/services/documentation/git_log_reader.rb
    app/services/documentation/knowledge_link_resolver.rb
    app/services/documentation/knowledge_link.rb
    app/services/documentation/markdown_renderer.rb
    app/services/documentation/naming.rb
    app/services/documentation/navigation.rb
    app/services/documentation/plain_text_renderer.rb
    app/services/embedding_processing_service.rb
    app/services/embedding_reprocessing_service.rb
    app/services/embeddings/activation_backfill.rb
    app/services/embeddings/default_model_migrator.rb
    app/services/embeddings/pending_backlog.rb
    app/services/extract_plain_text_processing_service.rb
    app/services/import_management_service.rb
    app/services/kanban_board_presenter.rb
    app/services/lalabase.rb
    app/services/lalabase/citations.rb
    app/services/lalabase/fence_guard.rb
    app/services/lalabase/github.rb
    app/services/lalabase/github/client.rb
    app/services/lalabase/indexer.rb
    app/services/lalabase/indexer/capability_generator.rb
    app/services/lalabase/indexer/embedding_columns.rb
    app/services/lalabase/indexer/git_cloner.rb
    app/services/lalabase/indexer/job_support.rb
    app/services/lalabase/indexer/repo_scanner.rb
    app/services/lalabase/indexer/scan_prompt.rb
    app/services/lalabase/indexer/secret_redaction.rb
    app/services/lalabase/indexer/symbol_persistence.rb
    app/services/lalabase/indexer/symbols.rb
    app/services/lalabase/indexer/symbols/ruby_extractor.rb
    app/services/lalabase/indexer/symbols/signature_extraction.rb
    app/services/lalabase/indexer/symbols/tree_sitter_grammar.rb
    app/services/lalabase/indexer/symbols/typescript_extractor.rb
    app/services/lalabase/indexer/symbols/walker.rb
    app/services/lalabase/indexer/vision_generator.rb
    app/services/lalabase/language_detector.rb
    app/services/lalabase/languages.rb
    app/services/lalabase/llm.rb
    app/services/lalabase/llm/action_registry.rb
    app/services/lalabase/llm/anthropic_provider.rb
    app/services/lalabase/llm/cost_calculator.rb
    app/services/lalabase/llm/factory.rb
    app/services/lalabase/llm/gate.rb
    app/services/lalabase/llm/open_ai_compatible_provider.rb
    app/services/lalabase/llm/open_ai_provider.rb
    app/services/lalabase/llm/provider.rb
    app/services/lalabase/llm/quota_ledger.rb
    app/services/lalabase/llm/token_usage.rb
    app/services/lalabase/llm/usage_tracking.rb
    app/services/lalabase/project_rag.rb
    app/services/lalabase/project_rag/content_area_registry.rb
    app/services/lalabase/project_rag/prompt_builder.rb
    app/services/lalabase/project_rag/retriever.rb
    app/services/lalabase/query_embedding.rb
    app/services/lalabase/repo_scope.rb
    app/services/lalabase/tools.rb
    app/services/markdown_to_action_text_service.rb
    app/services/mcp/dispatcher.rb
    app/services/mcp/idempotency_store.rb
    app/services/mcp/tool_call.rb
    app/services/meetings/participant_claim_matches.rb
    app/services/notifications/broadcast_service.rb
    app/services/notifications/fanout_service.rb
    app/services/notifications/group_key_builder.rb
    app/services/notifications/index_outcome_notifier.rb
    app/services/notifications/score_calculator.rb
    app/services/notifications/shared/preference_resolver.rb
    app/services/notifications/shared/scope_filter.rb
    app/services/notifications/suppressor.rb
    app/services/notifications/update_preferences_service.rb
    app/services/overview/portfolio_stats.rb
    app/services/post_update_service.rb
    app/services/power_search_service.rb
    app/services/projects/backlog_status_backfill_service.rb
    app/services/projects/default_attribute_service.rb
    app/services/projects/default_smart_folder_service.rb
    app/services/projects/due_date_backfill_service.rb
    app/services/projects/priority_level_backfill_service.rb
    app/services/prompt_building_service.rb
    app/services/remove_membership_service.rb
    app/services/sidebar_project_grouping_service.rb
    app/services/smart_folder_dissolver.rb
    app/services/smart_folder_query_builder.rb
    app/services/smart_folder_rule_factory.rb
    app/services/smart_folder_service.rb
    app/services/subscriptions/guest_ceiling.rb
    app/services/subscriptions/seat_counter.rb
    app/services/summary_processing_service.rb
    app/services/system_functions/resolver.rb
    app/services/text_processing_service.rb
    app/services/ticket_summary_service.rb
    app/services/ticket_timeline_service.rb
    app/services/tickets/filter.rb
    app/services/tickets/serializer.rb
    app/services/time_session_filter_service.rb
    app/services/time_session_group_billing_service.rb
    app/services/time_session_group_filter_service.rb
    app/services/time_session_navigation_service.rb
    app/services/user_data_exports/archive_writer.rb
    app/services/user_data_exports/builder.rb
    app/services/user_data_exports/generic_serializer.rb
    app/services/user_data_exports/registry.rb
    app/services/user_data_exports/serializers/email_logs_serializer.rb
    app/services/user_data_exports/serializers/memberships_serializer.rb
    app/services/user_data_exports/serializers/user_activities_serializer.rb
    app/services/wiki/markdown_serializer.rb
    app/services/wiki/mention_resolver.rb
    app/services/wiki/mention.rb
    app/services/wiki/note_backfill.rb
    app/services/wiki/reference_extractor.rb
    app/services/wiki/version_diff.rb
  ].freeze

  module_function

  # Rule 1a: class-level `.call` entry point.
  def class_call?(source)
    return true if source.match?(/^\s*def self\.call\b/)

    source.match?(/^\s*class << self\b/) && source.match?(/^\s*def call\b/)
  end

  # Rule 1b: explicitly declared entry point in the header comment.
  def declared_entry_point?(source)
    source.match?(/^#\s*Entry point:\s*\S/)
  end

  # Rule 3: at least one explanatory comment line before the first class/module.
  def header_comment?(source)
    head = source.lines.take_while { |l| !l.match?(/^\s*(class|module)\s/) }
    head.any? do |line|
      line.lstrip.start_with?('#') &&
        !line.match?(/frozen_string_literal|encoding:|warn_indent/)
    end
  end

  # Rule 2: #initialize takes only keyword args / splats / block (or none at all).
  def initialize_kwargs_only?(source)
    sig = initialize_signature(source)
    return true if sig.nil? || sig.strip.empty?

    split_params(sig).all? do |param|
      param == '...' ||
        param.match?(/\A(\*{1,2}[a-zA-Z_]\w*|\*{1,2}|&\w+)\z/) || # splats / block
        param.match?(/\A[a-z_]\w*:/) # keyword arg
    end
  end

  # Extracts the parameter list of the first #initialize, handling multi-line
  # signatures via paren balancing. Returns nil when there is no #initialize,
  # '' when it takes no parenthesized params.
  def initialize_signature(source)
    match = source.match(/^\s*def initialize\s*(\()?/)
    return nil unless match
    return '' unless match[1]

    depth = 1
    sig = +''
    idx = match.end(0)
    while depth.positive? && idx < source.length
      char = source[idx]
      depth += 1 if char == '('
      depth -= 1 if char == ')'
      sig << char if depth.positive?
      idx += 1
    end
    sig
  end

  # Splits a parameter list on top-level commas only (defaults may contain
  # nested commas inside (), [], {}).
  def split_params(signature)
    params = []
    current = +''
    depth = 0
    signature.each_char do |char|
      case char
      when '(', '[', '{'
        depth += 1
        current << char
      when ')', ']', '}'
        depth -= 1
        current << char
      when ','
        if depth.zero?
          params << current.strip
          current = +''
        else
          current << char
        end
      else
        current << char
      end
    end
    params << current.strip
    params.reject(&:empty?)
  end
end

RSpec.describe 'Service convention guard' do
  def service_files
    Dir[Rails.root.join('app/services/**/*.rb')]
      .map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }
      .reject { |f| ServiceConventionDetectors::EXCLUDED_SUBTREES.any? { |prefix| f.start_with?(prefix) } }
      .sort
  end

  def violations_for(path)
    source = File.read(Rails.root.join(path))
    violations = []
    unless ServiceConventionDetectors.class_call?(source) ||
           ServiceConventionDetectors.declared_entry_point?(source)
      violations << 'entry-point (kein `def self.call` und kein `# Entry point:`-Header)'
    end
    violations << 'initialize (positionale Argumente statt kwargs)' unless ServiceConventionDetectors.initialize_kwargs_only?(source)
    violations << 'header (keine erklaerende Kommentarzeile vor class/module)' unless ServiceConventionDetectors.header_comment?(source)
    violations
  end

  it 'alle Nicht-Legacy-Services erfuellen die Konvention (.call / kwargs / Header)' do
    offenders = (service_files - ServiceConventionDetectors::LEGACY_ALLOWLIST)
                .index_with { |f| violations_for(f) }
                .reject { |_, v| v.empty? }

    expect(offenders).to be_empty, <<~MSG
      Neue Service-Dateien verletzen die Konvention (CLAUDE.md "Service-Konvention"):

      #{offenders.map { |f, v| "  - #{f}\n      #{v.join("\n      ")}" }.join("\n")}

      Entweder auf `Klass.call(**kwargs)` + Header-Kommentar bringen oder (nur fuer
      Read-/Query-Objekte) den Entry-Point per `# Entry point: <methode>` deklarieren.
    MSG
  end

  it 'die Legacy-Allowlist enthaelt nur noch existierende Dateien' do
    stale = ServiceConventionDetectors::LEGACY_ALLOWLIST - service_files
    expect(stale).to be_empty, "Geloeschte/verschobene Dateien aus der Allowlist entfernen:\n#{stale.join("\n")}"
  end

  it 'die Legacy-Allowlist enthaelt keine bereits konformen Dateien (shrink-only)' do
    compliant = (ServiceConventionDetectors::LEGACY_ALLOWLIST & service_files).select { |f| violations_for(f).empty? }
    expect(compliant).to be_empty, <<~MSG
      Diese Dateien erfuellen die Konvention bereits — aus der Allowlist streichen:
      #{compliant.map { |f| "  - #{f}" }.join("\n")}
    MSG
  end

  describe 'detection logic (synthetic sources)' do
    d = ServiceConventionDetectors

    it 'erkennt def self.call und class << self / def call' do
      expect(d.class_call?("class Foo\n  def self.call(x:)\n  end\nend")).to be true
      expect(d.class_call?("class Foo\n  class << self\n    def call\n    end\n  end\nend")).to be true
      expect(d.class_call?("class Foo\n  def call\n  end\nend")).to be false
      expect(d.class_call?("class Foo\n  def self.callback\n  end\nend")).to be false
    end

    it 'erkennt den Entry-point-Header' do
      expect(d.declared_entry_point?("# Entry point: #can?\nclass Foo; end")).to be true
      expect(d.declared_entry_point?("# entry point missing\nclass Foo; end")).to be false
    end

    it 'erkennt erklaerende Header-Kommentare (Magic Comments zaehlen nicht)' do
      expect(d.header_comment?("# frozen_string_literal: true\n\nclass Foo; end")).to be false
      expect(d.header_comment?("# frozen_string_literal: true\n\n# Does a thing.\nclass Foo; end")).to be true
      expect(d.header_comment?("class Foo\n  # inner comment\nend")).to be false
    end

    it 'akzeptiert nur kwargs/Splats/Block in #initialize, auch mehrzeilig' do
      expect(d.initialize_kwargs_only?("class F\nend")).to be true
      expect(d.initialize_kwargs_only?("def initialize\nend")).to be true
      expect(d.initialize_kwargs_only?("def initialize(project:, id: nil)\nend")).to be true
      expect(d.initialize_kwargs_only?("def initialize(**opts)\nend")).to be true
      expect(d.initialize_kwargs_only?("def initialize(...)\nend")).to be true
      expect(d.initialize_kwargs_only?("def initialize(user)\nend")).to be false
      expect(d.initialize_kwargs_only?("def initialize(user, org: nil)\nend")).to be false
      expect(d.initialize_kwargs_only?("def initialize(user = User.new(a, b))\nend")).to be false
      expect(d.initialize_kwargs_only?("def initialize(\n  project:,\n  scope: {a: 1, b: 2}\n)\nend")).to be true
    end
  end
end

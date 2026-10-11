# frozen_string_literal: true

class SmartFolderQueryBuilder
  SUPPORTED_MODELS = {
    'Note' => Note,
    'Ticket' => Ticket,
    'Document' => Document,
    'TimeSession' => TimeSession,
    'Meeting' => Meeting
  }.freeze

  # Adding a dedicated target must not widen existing All views.
  ALL_MODELS = SUPPORTED_MODELS.slice(*SmartFolder::ALL_OBJECT_TYPES).freeze

  IDS_PER_GROUP_LIMIT = 10_000
  RESULTS_PER_MODEL_LIMIT = 1_000

  EAGER_LOADING = {
    'Note' => [:project],
    'Ticket' => %i[assignees project],
    'Document' => %i[current_version project],
    'TimeSession' => %i[project ticket creator],
    'Meeting' => %i[project creator meeting_participants]
  }.freeze

  attr_reader :smart_folder, :current_user

  def initialize(smart_folder, current_user = nil)
    @smart_folder = smart_folder
    @current_user = current_user || smart_folder.user
    @accessible_project_ids_cache = {}
  end

  def build_results_query
    if smart_folder.target_object_type == 'Meeting'
      scope = apply_permissions_filter(init_base_query(Meeting))
      return Meetings::ListQuery.call(scope: scope, smart_folder: smart_folder).preload(:project)
    end

    rule_groups = loaded_rule_groups
    return [] if rule_groups.empty?

    model_queries = build_model_queries(rule_groups)
    return [] if model_queries.empty?

    combine_and_sort_results(model_queries)
  end

  # Unbounded relation for paginated lists. The caller supplies its permission
  # scope; rules can only narrow it. OR groups remain SQL subqueries, never ids
  # truncated by the generic SmartFolder results preview limits.
  def filter_relation(scope)
    return scope.none unless smart_folder.target_object_type.in?([scope.klass.name, 'All'])
    return scope.none if smart_folder.target_object_type == 'All' && !ALL_MODELS.key?(scope.klass.name)

    base = scope.where(organisation_id: smart_folder.organisation_id)
    base = base.where(project_id: smart_folder.project_id) if smart_folder.project_id
    groups = loaded_rule_groups
    return base if groups.empty? && smart_folder.target_object_type == 'Meeting'

    model_name = scope.klass.name
    relevant_groups = extract_relevant_rules(groups, model_name)
    note_content_fix = requires_note_content_fix?(model_name, relevant_groups)
    queries = relevant_groups.filter_map do |rules|
      filtered = apply_group_rules(base, model_name, rules, note_content_fix)
      base.where(id: filtered.select(:id)) if filtered
    end
    queries.reduce { |left, right| left.or(right) } || base.none
  end

  private

  def loaded_rule_groups
    @loaded_rule_groups ||= smart_folder.smart_folder_rule_groups.includes(:smart_folder_rules).to_a
  end

  def build_model_queries(rule_groups)
    models_to_query = resolve_target_models
    model_queries = {}

    models_to_query.each do |model_name, model_class|
      query = build_and_permit_query(model_class, model_name, rule_groups)
      model_queries[model_name] = query if query
    end

    model_queries
  end

  def resolve_target_models
    target = smart_folder.target_object_type
    if target.present? && SUPPORTED_MODELS.key?(target)
      { target => SUPPORTED_MODELS[target] }
    else
      ALL_MODELS
    end
  end

  def build_and_permit_query(model_class, model_name, rule_groups)
    rule_based_query = build_rule_based_model_query(model_class, model_name, rule_groups)
    return nil unless rule_based_query

    permitted_query = apply_permissions_filter(rule_based_query)
    permitted_query if query_has_results?(permitted_query)
  end

  def build_rule_based_model_query(model_class, model_name, rule_groups)
    base_query = init_base_query(model_class)
    relevant_groups_rules = extract_relevant_rules(rule_groups, model_name)
    return nil if relevant_groups_rules.empty?

    all_matching_ids = collect_matching_ids(base_query, model_name, relevant_groups_rules)
    return base_query.none if all_matching_ids.empty?

    final_query = base_query.where(id: all_matching_ids)
    apply_eager_loading(final_query, model_name)
  end

  def extract_relevant_rules(rule_groups, model_name)
    rule_groups.filter_map do |group|
      applicable = group.smart_folder_rules.select { |rule| rule.applicable_to?(model_name) }
      applicable.sort_by(&:position) if applicable.any?
    end
  end

  def collect_matching_ids(base_query, model_name, relevant_groups_rules)
    note_content_fix = requires_note_content_fix?(model_name, relevant_groups_rules)

    group_queries = relevant_groups_rules.each_with_index.filter_map do |rules_in_group, group_index|
      apply_group_rules(base_query, model_name, rules_in_group, note_content_fix)
    rescue StandardError => e
      Rails.logger.error "Error composing query for group #{group_index}: #{e.message}"
      nil
    end

    return [] if group_queries.empty?

    combined = group_queries.reduce { |acc, q| acc.or(q) }
    combined.limit(IDS_PER_GROUP_LIMIT).pluck(:id)
  end

  def requires_note_content_fix?(model_name, relevant_groups_rules)
    return false unless model_name == 'Note'

    relevant_groups_rules.any? do |rules|
      fields = rules.map(&:field)
      fields.any? { |f| %w[created_at updated_at].include?(f) } && fields.include?('content')
    end
  end

  def apply_group_rules(base_query, model_name, rules_in_group, note_content_fix)
    if note_content_fix && model_name == 'Note'
      apply_note_content_fix_rules(base_query, rules_in_group, model_name)
    else
      apply_all_rules(base_query.dup, rules_in_group, model_name)
    end
  end

  def apply_note_content_fix_rules(base_query, rules_in_group, model_name)
    date_rules, content_rules, other_rules = partition_note_rules(rules_in_group)

    query = apply_all_rules(base_query.dup, other_rules, model_name)
    return nil unless query

    if content_rules.any?
      date_query = apply_all_rules(query.dup, date_rules, model_name)
      return nil unless query_has_results?(date_query)

      date_query
    else
      apply_all_rules(query, date_rules, model_name)
    end
  end

  def partition_note_rules(rules)
    date_rules = []
    content_rules = []
    other_rules = []

    rules.each do |rule|
      case rule.field
      when 'created_at', 'updated_at' then date_rules << rule
      when 'content' then content_rules << rule
      else other_rules << rule
      end
    end

    [date_rules, content_rules, other_rules]
  end

  def apply_all_rules(query, rules, model_name)
    rules.each do |rule|
      query = apply_single_rule(query, rule, model_name)
      return nil unless query
    end
    query
  rescue StandardError => e
    Rails.logger.error "Error applying filter for rule: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    nil
  end

  def apply_single_rule(query, rule, model_name)
    filter = rule.get_filter_class.new(rule)
    filter.apply(query, model_name)
  end

  def init_base_query(model_class)
    query = model_class.where(organisation_id: smart_folder.organisation_id)
    query = query.where(project_id: smart_folder.project_id) if smart_folder.project_id.present? && model_class.column_names.include?('project_id')
    query
  end

  def apply_permissions_filter(query)
    return query if current_user.account_admin_in?(ActsAsTenant.current_tenant)

    model_class = query.model

    # TimeSession has its own view tier (own/all PER PROJECT, persisted
    # TimeSessionPermission rows) that the area-based project filter below
    # cannot express: :time_sessions is not a ProjectPermission area, so
    # accessible_project_ids_for answered [] for every non-admin and this
    # method returned NONE — a time smart folder was silently empty for
    # everyone below account admin. Same single owner as the time list
    # (find_time_sessions) and the chat report: TimeSessionPolicy::Scope.
    # The former index_all_in_projects? probe (a method TimeSessionPolicy
    # never had) sat unreachable behind that [] and is gone with it.
    return TimeSessionPolicy::Scope.new(current_user, query).resolve if model_class == TimeSession

    accessible_ids = accessible_project_ids_for(model_class.name.underscore.pluralize.to_sym, :read)

    if model_class.column_names.include?('project_id')
      return query.none if accessible_ids == []

      query = query.where(project_id: accessible_ids) if accessible_ids.present?
    end

    query
  end

  def accessible_project_ids_for(area, access_type = :read)
    cache_key = "#{area}_#{access_type}"
    return @accessible_project_ids_cache[cache_key] if @accessible_project_ids_cache.key?(cache_key)

    ids = compute_accessible_project_ids(area, access_type)
    @accessible_project_ids_cache[cache_key] = ids
    ids
  rescue NameError => e
    Rails.logger.error "AccessCheck::ProjectAccessService not found: #{e.message}. Permissions might not be applied correctly."
    @accessible_project_ids_cache[cache_key] = []
    []
  rescue StandardError => e
    Rails.logger.error "Error fetching accessible project IDs for area '#{area}': #{e.message}"
    @accessible_project_ids_cache[cache_key] = []
    []
  end

  def compute_accessible_project_ids(area, access_type)
    model_class = area.to_s.classify.safe_constantize
    return nil unless model_class&.column_names&.include?('project_id')

    if smart_folder.project_id.present?
      service = AccessCheck::ProjectAccessService.new(current_user, smart_folder.project)
      service.can?(access_type, area) ? [smart_folder.project_id] : []
    else
      projects = AccessCheck::ProjectAccessService.accessible_projects(current_user, smart_folder.organisation)
      projects.select { |p| AccessCheck::ProjectAccessService.new(current_user, p).can?(access_type, area) }.pluck(:id)
    end
  end

  def apply_eager_loading(query, model_name)
    includes = EAGER_LOADING[model_name]
    includes ? query.includes(*includes) : query
  end

  def combine_and_sort_results(permitted_model_queries)
    combined_results = []

    permitted_model_queries.each do |model_name, query|
      next unless query_has_results?(query)

      model_results = query.limit(RESULTS_PER_MODEL_LIMIT).to_a
      combined_results.concat(model_results)
      Rails.logger.warn "SmartFolder (#{smart_folder.id}) query limit (#{RESULTS_PER_MODEL_LIMIT}) reached for model #{model_name}. Results might be incomplete." if model_results.size == RESULTS_PER_MODEL_LIMIT
    rescue StandardError => e
      Rails.logger.error "Error executing query for model #{model_name} in SmartFolder #{smart_folder.id}: #{e.message}"
    end

    sort_results(combined_results)
  end

  def sort_results(results)
    results ||= []

    sort_attr = case smart_folder.effective_sort_column
                when 'updated_at' then :updated_at
                when 'created_at' then :created_at
                when 'title' then :title
                when 'occurred_at' then :occurred_at
                when 'duration_minutes' then :duration_minutes
                else :updated_at
                end

    direction = smart_folder.effective_sort_direction == 'asc' ? :asc : :desc

    results.sort_by do |item|
      value = if sort_attr == :title
                extract_title(item).to_s.downcase
              else
                item.respond_to?(sort_attr) ? item.public_send(sort_attr) : nil
              end
      [value.nil? ? 1 : 0, value]
    end.tap { |sorted| sorted.reverse! if direction == :desc }
  end

  def extract_title(item)
    if item.respond_to?(:title) && item.title.present?
      item.title
    elsif item.is_a?(Document) && item.respond_to?(:current_version) && item.current_version&.title.present?
      item.current_version.title
    elsif item.respond_to?(:name) && item.name.present?
      item.name
    elsif item.is_a?(TimeSession) && item.respond_to?(:description) && item.description.present?
      item.description
    else
      "#{item.class.name} #{item.id}"
    end.to_s
  end

  def query_has_results?(query)
    return false if query.nil?
    return true unless query.is_a?(ActiveRecord::Relation)

    query.exists?
  end
end

# frozen_string_literal: true

require 'rails_helper'
require 'prism'

# What: outside Notifications::RowEvents (app/services/notifications/row_events.rb)
#   nothing in app/ or lib/ writes one of the four event fields of a notification
#   row that already exists: group_count, first_event_at, last_event_at, happened_at.
#   Folding one more event into a row is Notifications::RowEvents.fold!.
# Why: every inbox list orders by last_event_at and labels by happened_at, and
#   Posts::MarkRead matches a comment by first_event_at..last_event_at. The span may only widen,
#   because events of one bucket can arrive out of order (a retried outbox event).
#   Until 2026-11-24 (#274) the fold sat inline in GroupKeyBuilder and moved the
#   span inwards when an older event came in late. A rule that has to be
#   remembered at every write is not a rule.
# How: every .rb file under app/ and lib/ and every .rake file under lib/ is parsed
#   with Prism, so comments and strings that name a field are not writes, and a
#   call spread over several lines is one call. It refuses:
#   * a write through the attribute writer, with any receiver, self included:
#     `row.group_count = 1`, `row.group_count += 1`, `row.first_event_at ||= t`,
#     `row.last_event_at &&= t`, and the same as a target of a multiple assignment;
#   * an index write naming a field: `row[:group_count] = 1`, `+=`, `||=`, `&&=`;
#   * a call of WRITE_METHODS that names a field as a hash key (also inside a
#     `merge` of its argument), as a symbol or as a string argument, or in the
#     options of upsert_all and of the counter methods (update_only:,
#     on_duplicate:, touch:);
#   * the SQL text of such a call (update_all with a string, an interpolated
#     string, a heredoc, Arel.sql or the first element of an array).
#   A literal is read through a call without arguments (`<<~SQL.squish`,
#   `'...'.freeze`, `{ ... }.compact`, `%i[...].index_with { }`), through a
#   condition (`cond ? { ... } : {}`), `||` and `&&`, `begin` and a splat.
#   A new row is not counted: new, build, create, create!, insert and insert_all
#   with these keys, merged hashes included, are not WRITE_METHODS. Reading a
#   field (order, where, pluck, maximum) is not a write either.
# A tripwire, not a proof. Not seen: a write through send, public_send or __send__; a
#   field name held in a variable or a constant (`update!(FIELD => t)`); a hash
#   built elsewhere and handed over in a variable (`update!(attrs)`,
#   `upsert_all(rows)`), or picked by a method with arguments (`attrs.slice(:group_count)`);
#   SQL text built by a method with arguments (sanitize_sql_*, `format`, `%`, `+`) or held in
#   a constant; code inside `#{...}` of an interpolated string (its literal parts are
#   read); raw SQL through the connection (connection.execute, exec_update, an
#   Arel::UpdateManager); an association option that names a field
#   (`counter_cache: :group_count`, `touch: :last_event_at`); templates, specs and factories.
#   Counted although harmless: Hash#update and an index write on a plain hash read
#   the same as a write of a row, and a field set through its writer on a row that
#   is still new (`Notification.new.tap { |n| n.group_count = 1 }`) reads the same
#   as a write of an existing one. Build a hash with merge! and a new row with the
#   keys of create! or new instead.
module NotificationRowEventsGuard
  OWNER = 'app/services/notifications/row_events.rb'
  PATTERNS = %w[{app,lib}/**/*.rb lib/**/*.rake].freeze

  FIELDS = %w[group_count first_event_at last_event_at happened_at].freeze
  FIELD = /\b(?:#{FIELDS.join('|')})\b/
  WRITERS = FIELDS.map { |field| :"#{field}=" }.freeze

  # Each writes the columns it names, on a record or on a relation. bulk_transition! is
  # Notification's own bulk writer: it hands its keys to update_all.
  WRITE_METHODS = %i[
    update update! update_all update_columns update_column update_attribute update_attribute! assign_attributes
    attributes= write_attribute _write_attribute increment increment! decrement decrement! toggle toggle! touch
    touch_all upsert upsert_all update_counters increment_counter decrement_counter bulk_transition!
  ].freeze

  # An option of a write method whose value names the columns it writes.
  WRITING_OPTIONS = %w[update_only on_duplicate touch].freeze

  # A hash that a write method receives through one of these still names its keys.
  MERGERS = %i[merge merge! reverse_merge reverse_merge! with_defaults with_defaults! deep_merge deep_merge!].freeze

  ASSIGNMENTS = {
    Prism::CallOperatorWriteNode => 'operator assignment',
    Prism::CallOrWriteNode => 'or-assignment',
    Prism::CallAndWriteNode => 'and-assignment',
    Prism::CallTargetNode => 'multiple assignment'
  }.freeze

  INDEX_ASSIGNMENTS = {
    Prism::IndexOperatorWriteNode => 'index operator assignment',
    Prism::IndexOrWriteNode => 'index or-assignment',
    Prism::IndexAndWriteNode => 'index and-assignment',
    Prism::IndexTargetNode => 'index multiple assignment'
  }.freeze

  # Shrink-only. [count, reason]: the count is exact, a write fixed elsewhere lowers it.
  ALLOWED = {
    'app/models/notification.rb' =>
      [2, 'set_timestamps: two or-assignments before validation on create ' \
          '(before_validation :set_timestamps, on: :create); the row does not exist yet']
  }.freeze

  def self.files
    Dir[*PATTERNS.map { |pattern| Rails.root.join(pattern) }]
      .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
      .reject { |path| path == OWNER }.sort
  end

  def self.file_findings(path)
    result = Prism.parse_file(Rails.root.join(path).to_s)
    raise ArgumentError, "#{path} does not parse: #{result.errors.first&.message}" if result.failure?

    findings(result.value)
  end

  def self.source_findings(source)
    result = Prism.parse(source)
    raise ArgumentError, "sample does not parse: #{result.errors.first&.message}" if result.failure?

    findings(result.value)
  end

  # [line number, shape] of every write of an event field, in source order
  def self.findings(root)
    found = []
    pending = [root]
    until pending.empty?
      node = pending.pop
      shape = shape_of(node)
      found << [node.location.start_offset, node.location.start_line, shape] if shape
      pending.concat(node.compact_child_nodes)
    end
    found.sort.map { |_offset, line, shape| [line, shape] }
  end

  def self.shape_of(node)
    case node
    when Prism::CallNode then call_shape(node)
    when *ASSIGNMENTS.keys
      name = node.is_a?(Prism::CallTargetNode) ? node.name : node.write_name
      "#{ASSIGNMENTS.fetch(node.class)} of #{name.to_s.delete_suffix('=')}" if WRITERS.include?(name)
    when *INDEX_ASSIGNMENTS.keys
      named = names_in(node.arguments&.arguments&.first)
      "#{INDEX_ASSIGNMENTS.fetch(node.class)} of #{named.join(', ')}" if named.any?
    end
  end

  def self.call_shape(node)
    return "assignment of #{node.name.to_s.delete_suffix('=')}" if WRITERS.include?(node.name)

    arguments = Array(node.arguments&.arguments)
    if node.name == :[]=
      named = names_in(arguments.first)
      return named.any? ? "index assignment of #{named.join(', ')}" : nil
    end
    return unless WRITE_METHODS.include?(node.name)

    named = arguments.flat_map { |argument| names_in(argument) }.uniq
    "#{node.name} naming #{named.join(', ')}" if named.any?
  end

  # The fields a node names as a column: a symbol, a string (SQL text included), the
  # keys of a hash and the values of its WRITING_OPTIONS, the elements of an array,
  # a merged hash, Arel.sql, a literal passed through a call without arguments, both
  # branches of a condition, both sides of || and &&, a begin block and a splat.
  # Never the value of another key, never the arguments of another call.
  def self.names_in(node)
    case node
    when Prism::IfNode, Prism::UnlessNode then node.compact_child_nodes.drop(1).flat_map { |child| names_in(child) }
    when Prism::ElseNode, Prism::BeginNode then node.compact_child_nodes.flat_map { |child| names_in(child) }
    when Prism::OrNode, Prism::AndNode then names_in(node.left) + names_in(node.right)
    when Prism::SplatNode then names_in(node.expression)
    when Prism::SymbolNode, Prism::StringNode then node.unescaped.scan(FIELD)
    when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then node.parts.flat_map { |part| names_in(part) }
    when Prism::HashNode, Prism::KeywordHashNode then node.elements.flat_map { |element| names_in_element(element) }
    when Prism::ArrayNode then node.elements.flat_map { |element| names_in(element) }
    when Prism::ParenthesesNode then node.compact_child_nodes.flat_map { |child| names_in(child) }
    when Prism::StatementsNode then node.body.flat_map { |child| names_in(child) }
    when Prism::CallNode then names_in_call(node)
    else []
    end
  end

  def self.names_in_element(element)
    return names_in(element.value) if element.is_a?(Prism::AssocSplatNode)

    key = names_in(element.key)
    option = element.key.is_a?(Prism::SymbolNode) && WRITING_OPTIONS.include?(element.key.unescaped)
    option ? key + names_in(element.value) : key
  end

  def self.names_in_call(node)
    arguments = Array(node.arguments&.arguments)
    if MERGERS.include?(node.name)
      names_in(node.receiver) + arguments.flat_map { |argument| names_in(argument) }
    elsif node.name == :sql && node.receiver&.slice&.delete_prefix('::') == 'Arel'
      names_in(arguments.first)
    elsif node.receiver && arguments.empty?
      names_in(node.receiver)
    else
      []
    end
  end

  def self.counts
    files.index_with { |file| file_findings(file).size }.reject { |_, count| count.zero? }
  end

  # Files with more writes than the list allows, or with writes and no entry.
  def self.over(counts, allowed)
    counts.select { |file, count| count > allowed.fetch(file, [0]).first }
  end

  # Entries that allow more than is left: a fixed write must lower its entry.
  def self.stale(counts, allowed)
    allowed.filter_map { |file, (limit, _why)| file if counts.fetch(file, 0) < limit }
  end
end

RSpec.describe 'Notification event fields are folded only by Notifications::RowEvents', :ci_guard,
               type: :architecture do
  it 'finds no write of an event field beyond the allow list' do
    allowed = NotificationRowEventsGuard::ALLOWED
    over = NotificationRowEventsGuard.over(NotificationRowEventsGuard.counts, allowed).map do |file, count|
      lines = File.readlines(Rails.root.join(file))
      found = NotificationRowEventsGuard.file_findings(file).map do |line, shape|
        "    #{file}:#{line}: #{shape}: #{lines[line - 1].strip}"
      end
      "  #{file} (#{count}, allowed #{allowed.fetch(file, [0]).first}):\n#{found.join("\n")}"
    end

    expect(over).to be_empty, <<~MSG
      These write group_count, first_event_at or last_event_at of a notification row outside
      #{NotificationRowEventsGuard::OWNER}:
      #{over.join("\n")}

      A new writer calls Notifications::RowEvents.fold! instead: it is the one place that folds an
      event into an existing row, and the span it keeps only widens. A row that does not exist yet
      takes the fields as keys of create! or new.
    MSG
  end

  it 'keeps every allow-list count at what is actually left' do
    stale = NotificationRowEventsGuard.stale(NotificationRowEventsGuard.counts, NotificationRowEventsGuard::ALLOWED)

    expect(stale).to be_empty, "Lower these entries of NotificationRowEventsGuard::ALLOWED:\n#{stale.join("\n")}"
  end

  describe 'the count checks' do
    let(:allowed) { { 'a.rb' => [2, 'why'], 'b.rb' => [1, 'why'] } }

    it 'reports a file over its entry, or with no entry at all' do
      expect(NotificationRowEventsGuard.over({ 'a.rb' => 3, 'b.rb' => 1, 'c.rb' => 1 }, allowed).keys)
        .to eq(%w[a.rb c.rb])
    end

    it 'reports an entry above what is left, by one already' do
      expect(NotificationRowEventsGuard.stale({ 'a.rb' => 1, 'b.rb' => 1 }, allowed)).to eq(['a.rb'])
      expect(NotificationRowEventsGuard.stale({ 'a.rb' => 2 }, allowed)).to eq(['b.rb'])
    end
  end

  describe 'the scan' do
    it 'reads Ruby and rake files under app/ and lib/, and leaves the owner out' do
      files = NotificationRowEventsGuard.files

      expect(files).to include('app/services/notifications/group_key_builder.rb', 'app/models/notification.rb')
      expect(files.grep(%r{\Alib/.+\.rake\z})).not_to be_empty
      expect(files).not_to include(NotificationRowEventsGuard::OWNER)
    end
  end

  describe 'recognises the shapes it guards against' do
    def found?(source)
      NotificationRowEventsGuard.source_findings(source).any?
    end

    it 'finds every write of a field' do
      writes = [
        'row.group_count = 2',
        'self.last_event_at = Time.current',
        'row&.first_event_at = stamp',
        'row.group_count += 1',
        'self.group_count -= 1',
        'row.first_event_at ||= stamp',
        'row.last_event_at &&= stamp',
        'row.group_count, other.value = 1, 2',
        'row[:group_count] = 1',
        "self['last_event_at'] = stamp",
        'row[:group_count] += 1',
        'row[:first_event_at] ||= stamp',
        'row[:last_event_at] &&= stamp',
        'row[:group_count], other = 1, 2',
        'row.update(group_count: 2)',
        "row.update!('last_event_at' => stamp)",
        'row.update!(attrs.merge(last_event_at: stamp))',
        'row.update!(**attrs, first_event_at: stamp)',
        'scope.update_all(group_count: 0)',
        'scope.update_all({ last_event_at: stamp })',
        "scope.update_all('notifications.last_event_at' => stamp)",
        'row.update_columns(first_event_at: stamp)',
        'row.update_column(:group_count, 3)',
        "row.update_attribute('last_event_at', stamp)",
        'row.update_attribute!(:group_count, 2)',
        "row._write_attribute('last_event_at', stamp)",
        'scope.touch_all(:last_event_at)',
        'row.assign_attributes(group_count: 1)',
        'row.attributes = { last_event_at: stamp }',
        'row.write_attribute(:first_event_at, stamp)',
        'row.increment(:group_count)',
        'row.increment!(:group_count, 2)',
        'row.decrement(:group_count)',
        'row.decrement!(:group_count)',
        'row.toggle(:group_count)',
        'row.toggle!(:group_count)',
        'row.touch(:last_event_at)',
        'Notification.upsert({ id: row_id, group_count: 2 })',
        'Notification.upsert_all([{ id: row_id, last_event_at: stamp }])',
        'Notification.upsert_all(rows, update_only: [:last_event_at])',
        "Notification.upsert_all(rows, on_duplicate: Arel.sql('group_count = notifications.group_count + 1'))",
        'Notification.update_counters(row_id, group_count: 1)',
        'Notification.update_counters(row_id, other_count: 1, touch: :last_event_at)',
        'Notification.increment_counter(:group_count, row_id)',
        'Notification.decrement_counter(:group_count, row_id)',
        "scope.update_all('group_count = group_count + 1')",
        "scope.update_all(\"last_event_at = '\#{stamp}'\")",
        "scope.update_all(['first_event_at = ?', stamp])",
        "scope.update_all(Arel.sql('last_event_at = now()'))",
        "scope.update_all(<<~SQL)\n  group_count = 0\nSQL\n",
        "scope.update_all(<<~SQL.squish)\n  group_count = group_count + 1\nSQL\n",
        "scope.update_all('last_event_at = now()'.freeze)",
        'row.update!({ last_event_at: stamp }.compact)',
        'row.update!({ group_count: 1 }.with_indifferent_access)',
        'row.update!(%i[last_event_at].index_with { stamp })',
        'row.update!(cond ? { first_event_at: stamp } : {})',
        'row.update!(attrs || { group_count: 1 })',
        "row.update!(begin\n  { last_event_at: stamp }\nend)\n",
        "scope.update_all(*['first_event_at = ?', stamp])",
        "scope\n  .where(state: :read)\n  .update_all(\n    last_event_at: stamp\n  )\n",
        "scope.unread.bulk_transition!(state: 'queued', last_event_at: stamp)"
      ]

      aggregate_failures do
        writes.each { |source| expect(found?(source)).to be(true), "not found: #{source}" }
      end
    end

    it 'counts each write, and names its line and its shape' do
      source = <<~RUBY
        row.group_count += 1
        # row.last_event_at = stamp
        row.first_event_at = [row.first_event_at, stamp].min
        row.update!(last_event_at: stamp, group_count: 2)
      RUBY

      expect(NotificationRowEventsGuard.source_findings(source)).to eq(
        [[1, 'operator assignment of group_count'], [3, 'assignment of first_event_at'],
         [4, 'update! naming last_event_at, group_count']]
      )
    end

    it 'leaves a new row, a read, a comment and a string alone' do
      others = [
        'Notification.new(group_count: 1, first_event_at: stamp, last_event_at: stamp)',
        'project.notifications.build(group_count: 1)',
        'Notification.create(group_count: 1, last_event_at: stamp)',
        "Notification.create!(\n  params.merge(\n    group_count: 1,\n    first_event_at: stamp,\n    last_event_at: stamp\n  )\n)\n",
        'Notification.insert({ group_count: 1, first_event_at: stamp })',
        'Notification.insert_all([{ last_event_at: stamp }])',
        'Notification.order(last_event_at: :desc, id: :desc)',
        'Notification.where(first_event_at: ..stamp)',
        "Notification.where('group_count < ?', 5)",
        'Notification.pluck(:group_count)',
        'Notification.maximum(:last_event_at)',
        'delegate :group_count, :last_event_at, to: :notification',
        "# row.group_count += 1\n",
        "# scope.update_all('last_event_at = now()')\n",
        "note = 'row.update!(last_event_at: stamp)'",
        "sql = 'group_count = group_count + 1'",
        'group_count = 1',
        '@group_count = 2',
        'last_event_at = [first, second].max',
        'row.update!(state: :read, read_at: stamp)',
        "row.update!(note: 'group_count')",
        "scope.update_all(score: Arel.sql('group_count * 2'))",
        "scope.update_all('state = 1'.freeze)",
        'row.update!(cond ? { state: :read } : {})',
        'row.update!(summary_for(:group_count))',
        'row.update!(label: summary.group_count)',
        'row.update!(previous_last_event_at: stamp)',
        "row.last_event_at_label = 'x'",
        'Notification.upsert_all(rows, unique_by: :id)',
        'row.touch',
        "scope.unread.bulk_transition!(state: 'read', read_at: stamp)"
      ]

      aggregate_failures do
        others.each { |source| expect(found?(source)).to be(false), "found, but is no write: #{source}" }
      end
    end
  end
end

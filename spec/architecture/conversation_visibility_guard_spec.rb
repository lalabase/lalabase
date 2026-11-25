# frozen_string_literal: true

require 'rails_helper'
require 'prism'
require 'tmpdir'

# What: a conversation is read only by somebody who takes part in it and is an
#   active member of its organisation. The rule has one place, the scope
#   Conversation.visible_to(user). Conversation#visible_to?, #visible_participants
#   and ConversationPost.visible_to are built on it, and ConversationPolicy asks
#   only it. No right on a project opens a conversation (its project is only a
#   label), and no admin role does.
# Why: the rule for private comments lived in one policy until five readers had
#   forgotten it (post_visibility_guard_spec.rb). Nothing reads these tables yet
#   but the personal data export, so this guard stands before the first reader
#   does, and no read path can grow past the rule. A rule that has to be
#   remembered at every read is not a rule.
# How: source text and syntax trees only (Prism); no model is loaded. The three
#   models are known by their constants, Conversation, ConversationPost and
#   ConversationParticipant, also with a leading `::`. Not by the word: the module
#   Conversations, ConversationPolicy, ConversationsController, Foo::Conversation
#   and a variable named conversation are other things. Five refusals:
#   1. Everywhere under app/ but in the two places that keep the rule
#      (KEEPER_DIRECTORIES: the models and the policies), in .rb and .erb files,
#      also in a directory that is added later, a model
#      constant stands only where the list allows it: as the receiver of a call
#      of SAFE_CALLS (`Conversation.visible_to(user)`, and the chain behind it may
#      go on), in front of `::` (`ConversationPost::KINDS`), as an argument of a
#      call or a value of its keyword arguments (`policy_scope(Conversation)`,
#      `record.is_a?(Conversation)`), or in a `when`. Everything else is a
#      finding: `Conversation.where(...)`, `.find`, `.all`, `.count`, a constant
#      assigned or returned. So is SQL text: a string literal (plain,
#      interpolated, a heredoc, `%()`) that names one of the three tables behind
#      JOIN or FROM.
#   2. In the same files, a read through an association name: `association`,
#      includes, preload, eager_load, joins, left_joins, left_outer_joins or
#      references naming conversation_posts, conversation_participants or
#      conversations, as a symbol or a string, nested in arrays and hashes, on
#      any receiver. A preloaded association holds every row, whatever the rule
#      says.
#   3. The words `project` and `account_admin` do not stand in the rule: not in
#      the bodies RULE_FILES names in the two models, and nowhere in the policy.
#      Comments are left out; everything else is text, in any case and inside a
#      longer name (`project_id`, `Project`, a SQL string). A file or a body that
#      is not found is red: a renamed method must not empty the check.
#   4. A file under app/ that names a model sends no Turbo broadcast
#      (`broadcast_append_to` and its family, `broadcasts_to` and its family). A
#      stream reaches everybody who listens to it, and no rule is asked on the way.
#   5. The assistant, the embeddings, the chats, the assistant's tools and the
#      admin area (CLOSED_DIRECTORIES) do not name a model at all.
#   OWNERS exempts a file from refusals 1 and 2, never from 3, 4 or 5.
#   A template is read as the Ruby of its tags. A file that does not parse raises.
# A tripwire against accidental readers, not a proof. Not seen:
#   * a read built at run time: `'Conversation'.constantize`, `send`, a class held
#     in a variable or handed over from elsewhere (`model.where(...)`), and what a
#     call does with a constant it got as an argument;
#   * a read through an association on a record (`conversation.conversation_posts`),
#     which is fine when the record came through the rule and wrong when it did not;
#   * a preload or a join under another name, such as the singular on a model that
#     belongs to a conversation (`includes(:conversation)`): refusal 2 reads the
#     three names above only;
#   * a chain that starts with the rule and drops it again
#     (`Conversation.visible_to(user).unscope(:where)`);
#   * a reader that only shows fields of a notification row about a conversation;
#   * app/models, app/policies and lib/ for refusals 1 and 2: the models keep the
#     rule, and the policy is read by refusal 3;
#   * SQL built from parts or through Arel, and a table named in a string without
#     JOIN or FROM right in front of it (`from('conversations')`, a second table
#     behind a comma);
#   * for refusal 3, a method the rule calls: only the named bodies are read, and
#     what the policy answers is held by its own specs;
#   * for refusal 4, a broadcast in a file that names no model (a job that is
#     handed a record and streams it), a broadcast named as a symbol
#     (`after_commit :broadcast_refresh`), and the application's own broadcast_*
#     methods, which send counts (`broadcast_badge_update`);
#   * a template that is no .erb file (another template language, a template held
#     in a string), and a tag behind a Ruby comment of an earlier tag on the same
#     line (the template compiler does not run it either).
#   Counted although harmless: a class of the same name inside a namespace when it
#   is written without the namespace (`module Foo; Conversation.all; end`), a type
#   test written as `Conversation === record` (use `is_a?` or a `when`), a model
#   constant in an array or in a hash literal, prose in a string that reads like
#   SQL ("removed from conversations"), a method of the application that
#   carries the name of a Turbo broadcast
#   (Notifications::BroadcastService#broadcast_update) in a file that names a
#   model, and a preload of the posts behind the rule
#   (`Conversation.visible_to(user).includes(:conversation_posts)`): whoever reads
#   a conversation reads all of its posts, but the list of its participants holds
#   deactivated members too, and one refusal for both is the simpler rule.
module ConversationVisibilityGuard
  MODELS = %w[Conversation ConversationPost ConversationParticipant].freeze
  TABLES = %w[conversations conversation_posts conversation_participants].freeze
  ASSOCIATIONS = %w[conversations conversation_posts conversation_participants].freeze

  # Where the rule is kept, not read: the models and the policy.
  KEEPER_DIRECTORIES = %w[app/models app/policies].freeze

  # Where readers live today. Refusals 1 and 2 read every other directory under
  # app/ as well (reader_files), so a new one is read from its first file on;
  # these are named so that a renamed directory cannot empty the walk unseen.
  READER_DIRECTORIES = %w[
    app/channels app/controllers app/services app/queries app/mailers app/components app/views app/presenters app/jobs
    app/helpers
  ].freeze

  # Places that must not know the three models at all
  CLOSED_DIRECTORIES = %w[
    app/services/assistant app/services/embeddings app/services/chats app/services/lalabase/tools
    app/controllers/admin app/views/admin
  ].freeze

  # What may be called on a model constant. A list of what may stand, never of
  # what may not: a new way of reading is a finding without anybody adding it.
  SAFE_CALLS = [
    :visible_to,           # the rule itself; a chain behind it stays inside the rule
    :new,                  # builds a row in memory, reads none
    :create, :create!,     # write a row
    :model_name,           # the name of the model, for routes, params and labels
    :name,                 # the name of the class as text
    :table_name,           # the name of the table as text
    :human_attribute_name, # the label of a field
    :transaction           # opens a transaction; what runs inside is read on its own
  ].freeze

  # Calls that read rows through the association they name
  ASSOCIATION_CALLS = %i[association includes preload eager_load joins left_joins left_outer_joins references].freeze

  # One of the three tables behind JOIN or FROM: any case, quoted or not, with or
  # without the schema. conversations_archive is another table.
  SQL_READ = /\b(?:JOIN|FROM)\s+(?:["`]?public["`]?\.)?["`]?(#{TABLES.join('|')})(?![A-Za-z0-9_])/i

  # Shrink-only: a file that reads without the rule on purpose, and why. It is
  # exempt from refusals 1 and 2 only. An entry without a finding left fails, and
  # so does an entry for a file that is gone.
  OWNERS = {
    'app/services/user_data_exports/registry.rb' =>
      "the personal data export lists a person's own rows by user_id, dates only, " \
      'inside the tenant of each of their organisations'
  }.freeze

  # Where the rule lives. Only the named bodies of a model are read: the model as
  # a whole may name the project, which is the label of a conversation.
  RULE_FILES = {
    'app/models/conversation.rb' => { scopes: %i[visible_to], methods: %i[visible_to? visible_participants] },
    'app/models/conversation_post.rb' => { scopes: %i[visible_to] },
    'app/policies/conversation_policy.rb' => { whole: true }
  }.freeze

  # The whole name around a forbidden word, so the finding says project_id
  FORBIDDEN_WORD = /\w*(?:project|account_admin)\w*/i

  # Turbo's broadcasts: broadcast_<stem>, _to, _later and _later_to, and the
  # declarations of a model. Not every method that starts with broadcast_.
  BROADCAST_STEMS = %w[append prepend replace update before after remove action refresh render stream].freeze
  BROADCAST = /\Abroadcast_(?:#{BROADCAST_STEMS.join('|')})(?:_later)?(?:_to)?\z/
  BROADCAST_DECLARATIONS = %i[broadcasts broadcasts_to broadcasts_refreshes broadcasts_refreshes_to].freeze

  # The tag pattern of Erubi, the template compiler of Rails: an opening mark
  # (`=`, `==`, `-`, `#` for a comment, `%` for a literal tag), the code, a closing mark
  ERB_TAG = /<%(={1,2}|-|\#|%)?(.*?)([-=])?%>/m

  # The syntax tree of one source. A source that does not parse raises: it is
  # never read as clean.
  def self.parse(source, erb: false, name: 'sample')
    result = Prism.parse(erb ? ruby_of_template(source) : source)
    raise ArgumentError, "#{name} does not parse: #{result.errors.first&.message}" if result.failure?

    result
  end

  # The Ruby of a template's tags, every character on its own line and column,
  # the rest blank. A `;` stands where a tag closes, as the template compiler
  # writes one, and all of it is the body of a method, as Rails compiles a
  # template (so a `yield` parses).
  def self.ruby_of_template(source)
    ruby = source.gsub(/[^\n]/, ' ')
    source.to_enum(:scan, ERB_TAG).each do
      tag = Regexp.last_match
      next if %w[# %].include?(tag[1])

      ruby[tag.begin(2), tag[2].length] = tag[2]
      ruby[tag.end(0) - 2] = ';'
    end
    "def __template__;#{ruby}\nend\n"
  end

  # Every node of a tree, each with the nodes above it (the nearest last)
  def self.walk(node, above = [], &block)
    yield node, above
    above.push(node)
    node.compact_child_nodes.each { |child| walk(child, above, &block) }
    above.pop
  end

  # The name of the model a node stands for: the bare constant or `::Conversation`.
  # A longer name is another constant, and Foo::Conversation is a path with a parent.
  def self.model(node)
    name = case node
           when Prism::ConstantReadNode then node.name.to_s
           when Prism::ConstantPathNode then node.name.to_s if node.parent.nil?
           end
    name if MODELS.include?(name)
  end

  # Refusals 1 and 2: [line, shape] of every read past the rule in one source
  def self.reads(source, erb: false, name: 'sample')
    found = []
    walk(parse(source, erb: erb, name: name).value) do |node, above|
      shape = class_read(node, above)
      found << [node.location.start_line, shape] if shape
      shape = association_read(node)
      found << [call_line(node), shape] if shape
      found.concat(sql_reads(node)) if string?(node) && !interpolated?(above.last)
    end
    found.uniq.sort
  end

  # The shape of a model constant that stands where the list does not allow it
  def self.class_read(node, above)
    name = model(node)
    return unless name

    parent = above.last
    case parent
    when Prism::CallNode
      # The only place of a constant right below a call is its receiver
      "#{name}.#{parent.name}" unless SAFE_CALLS.include?(parent.name)
    when Prism::ConstantPathNode, Prism::WhenNode
      # In front of `::`, or a type test. The body of a `when` is not below it directly.
      nil
    when Prism::ArgumentsNode
      "bare #{name}" unless above[-2].is_a?(Prism::CallNode)
    when Prism::AssocNode
      "bare #{name}" unless parent.value.equal?(node) && keyword_arguments_of_a_call?(above)
    else
      "bare #{name}"
    end
  end

  # above ends with: a call, its arguments, the keywords among them, one pair
  def self.keyword_arguments_of_a_call?(above)
    above[-2].is_a?(Prism::KeywordHashNode) && above[-3].is_a?(Prism::ArgumentsNode) && above[-4].is_a?(Prism::CallNode)
  end

  # The shape of a call that reads rows through an association of the three models
  def self.association_read(node)
    return unless node.is_a?(Prism::CallNode) && ASSOCIATION_CALLS.include?(node.name)

    named = association_names(node.arguments)
    "#{node.name} naming #{named.join(', ')}" if named.any?
  end

  def self.association_names(node)
    case node
    when Prism::SymbolNode, Prism::StringNode
      ASSOCIATIONS & [node.unescaped]
    when Prism::ArgumentsNode, Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::AssocNode,
         Prism::SplatNode, Prism::ParenthesesNode, Prism::StatementsNode
      node.compact_child_nodes.flat_map { |child| association_names(child) }.uniq
    else
      []
    end
  end

  # The line a call is named on, which is not its first line in a broken chain
  def self.call_line(node)
    (node.message_loc || node.location).start_line
  end

  def self.string?(node)
    node.is_a?(Prism::StringNode) || node.is_a?(Prism::XStringNode) || interpolated?(node)
  end

  # Also what Prism makes of a heredoc with several lines and of two literals side by side
  def self.interpolated?(node)
    node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedXStringNode)
  end

  # [line, shape] of every table of the three that a string literal names behind
  # JOIN or FROM. The literal is read as one text, so FROM at the end of one line
  # of a heredoc and the table on the next are one read.
  def self.sql_reads(node)
    text = String.new
    starts = pieces(node).map do |piece, line|
      start = [text.bytesize, line]
      text << piece
      start
    end
    text.to_enum(:scan, SQL_READ).map do
      match = Regexp.last_match
      start, line = starts.reverse_each.find { |offset, _line| offset <= match.begin(1) }
      [line + text[start...match.begin(1)].count("\n"), "SQL text naming #{match[1].downcase}"]
    end
  end

  # The text of a string literal piece by piece, each with the line it starts
  # on. Interpolated code is a NUL: it is no table name, and it ends one.
  def self.pieces(node)
    case node
    when Prism::StringNode, Prism::XStringNode then [[node.unescaped.b, node.content_loc.start_line]]
    when Prism::InterpolatedStringNode, Prism::InterpolatedXStringNode then node.parts.flat_map { |part| pieces(part) }
    else [["\0".b, node.location.start_line]]
    end
  end

  # Refusal 3: [line, text] of every forbidden word in the named bodies of one
  # source (in the whole source with whole: true), and of every body that is missing
  def self.rule_words(source, scopes: [], methods: [], whole: false, name: 'sample')
    result = parse(source, name: name)
    text = without_comments(source, result.comments)
    bodies = rule_bodies(result.value, scopes, methods)
    wanted = scopes.map { |scope| "scope #{scope}" } + methods.map { |method| "method #{method}" }
    missing = (wanted - bodies.map(&:first)).map { |label| [1, "no #{label} found"] }
    found = bodies.flat_map do |label, body|
      words_in(text[body.location.start_offset...body.location.end_offset], body.location.start_line, label)
    end
    found.concat(words_in(text, 1, 'file')) if whole
    missing + found
  end

  # The source as bytes, every comment blanked in place
  def self.without_comments(source, comments)
    text = source.b
    comments.each do |comment|
      text[comment.location.start_offset, comment.location.length] = ' ' * comment.location.length
    end
    text
  end

  # [label, node] of the second argument of `scope :name, ...` (a lambda in
  # either spelling) and of the instance methods asked for
  def self.rule_bodies(root, scopes, methods)
    bodies = []
    walk(root) do |node, _above|
      if node.is_a?(Prism::CallNode) && node.name == :scope && node.receiver.nil?
        named, body = node.arguments&.arguments
        scope = named.unescaped.to_sym if named.is_a?(Prism::SymbolNode)
        bodies << ["scope #{scope}", body] if body && scopes.include?(scope)
      elsif node.is_a?(Prism::DefNode) && node.receiver.nil? && methods.include?(node.name)
        bodies << ["method #{node.name}", node]
      end
    end
    bodies
  end

  def self.words_in(text, first_line, label)
    text.to_enum(:scan, FORBIDDEN_WORD).map do
      match = Regexp.last_match
      [first_line + match.pre_match.count("\n"), "#{match[0]} in the #{label}"]
    end
  end

  # Refusal 4: [line, call] of every Turbo broadcast in a source that names a
  # model. A source that names none is not read for broadcasts.
  def self.broadcasts(source, erb: false, name: 'sample')
    calls = []
    names_a_model = false
    walk(parse(source, erb: erb, name: name).value) do |node, _above|
      names_a_model ||= !model(node).nil?
      calls << [call_line(node), node.name.to_s] if node.is_a?(Prism::CallNode) && broadcast?(node.name)
    end
    names_a_model ? calls.sort : []
  end

  def self.broadcast?(method)
    BROADCAST_DECLARATIONS.include?(method) || method.to_s.match?(BROADCAST)
  end

  # Refusal 5, and "names a model" for refusal 4: [line, name] of every mention
  # of a model constant, in any position
  def self.mentions(source, erb: false, name: 'sample')
    found = []
    walk(parse(source, erb: erb, name: name).value) do |node, _above|
      named = model(node)
      found << [node.location.start_line, named] if named
    end
    found.sort
  end

  # Every .rb and .erb file below the directories, as paths from the root
  def self.files(directories, root: Rails.root)
    directories.flat_map { |directory| Dir[root.join(directory, '**/*.{rb,erb}')] }
               .map { |path| Pathname(path).relative_path_from(root).to_s }.uniq.sort
  end

  # Every file refusals 1 and 2 read: all of app/ outside the keepers of the rule
  def self.reader_files(root: Rails.root)
    files(%w[app], root: root).reject { |file| KEEPER_DIRECTORIES.any? { |directory| file.start_with?("#{directory}/") } }
  end

  # One check (:reads, :broadcasts, :mentions) on one file of the tree, as
  # "file:line: finding"
  def self.in_file(check, file)
    public_send(check, Rails.root.join(file).read, erb: file.end_with?('.erb'), name: file)
      .map { |line, finding| "#{file}:#{line}: #{finding}" }
  end

  # Refusal 3 on the files that hold the rule. A file that is gone is a finding.
  def self.rule_findings(rule_files)
    rule_files.flat_map do |file, bodies|
      path = Rails.root.join(file)
      next ["#{file}: no such file"] unless path.exist?

      rule_words(path.read, name: file, **bodies).map { |line, finding| "#{file}:#{line}: #{finding}" }
    end
  end

  # The entries of an allow list that exempt nothing: a file that is gone, and a
  # file without a finding of refusal 1 or 2 left
  def self.stale(owners)
    owners.keys.filter_map do |file|
      if !Rails.root.join(file).exist?
        "#{file}: no such file"
      elsif in_file(:reads, file).empty?
        "#{file}: no finding left"
      end
    end
  end
end

RSpec.describe 'Conversation reads go through Conversation.visible_to', :ci_guard, type: :architecture do
  # The shapes of the reads (refusals 1 and 2) in one sample
  def shapes(source, **options)
    ConversationVisibilityGuard.reads(source, **options).map(&:last)
  end

  it 'finds no read past the rule outside the allow list' do
    files = ConversationVisibilityGuard.reader_files
    offenders = (files - ConversationVisibilityGuard::OWNERS.keys).flat_map do |file|
      ConversationVisibilityGuard.in_file(:reads, file)
    end

    expect(offenders).to be_empty, <<~MSG
      These read conversations past the rule:
      #{offenders.join("\n")}

      What one person reads comes from policy_scope(Conversation) or Conversation.visible_to(user),
      and the posts and participants of a conversation from a record found that way. An association
      of the three models is never preloaded or joined: it holds every row, whatever the rule says.
      A reader that goes without the rule on purpose gets an entry in
      ConversationVisibilityGuard::OWNERS, with its reason.
    MSG
  end

  it 'keeps no allow-list entry that exempts nothing' do
    stale = ConversationVisibilityGuard.stale(ConversationVisibilityGuard::OWNERS)

    expect(stale).to be_empty, "Remove these from ConversationVisibilityGuard::OWNERS:\n#{stale.join("\n")}"
  end

  it 'finds neither the project nor an admin role in the rule and in the policy' do
    found = ConversationVisibilityGuard.rule_findings(ConversationVisibilityGuard::RULE_FILES)

    expect(found).to be_empty, <<~MSG
      The rule for reading a conversation asks two things only: does the person take part, and are
      they an active member of its organisation.
      #{found.join("\n")}

      The project of a conversation is a label and opens nothing, and no admin role reads along.
      A body that is "not found" was renamed or moved: name its new place in
      ConversationVisibilityGuard::RULE_FILES, so the check does not run empty.
    MSG
  end

  it 'finds no Turbo broadcast in a file that names one of the three models' do
    found = ConversationVisibilityGuard.files(%w[app]).flat_map do |file|
      ConversationVisibilityGuard.in_file(:broadcasts, file)
    end

    expect(found).to be_empty, <<~MSG
      These files name a model of conversations and send a Turbo broadcast:
      #{found.join("\n")}

      A stream reaches everybody who listens to it, and nobody asks Conversation.visible_to on the
      way. This refusal has no allow list.
    MSG
  end

  it 'finds none of the three models where they must not be known' do
    found = ConversationVisibilityGuard.files(ConversationVisibilityGuard::CLOSED_DIRECTORIES).flat_map do |file|
      ConversationVisibilityGuard.in_file(:mentions, file)
    end

    expect(found).to be_empty, <<~MSG
      These name a model of conversations in a place that must not know them
      (#{ConversationVisibilityGuard::CLOSED_DIRECTORIES.join(', ')}):
      #{found.join("\n")}

      A conversation is read by the people who take part in it, and no admin role opens it. So the
      assistant, its tools, the embeddings, the chats and the admin area do not name these models
      at all, not even through the rule. This refusal has no allow list.
    MSG
  end

  # Pinned so a broken glob or a renamed directory cannot pass by reading nothing
  describe 'the walks' do
    it 'reads Ruby files and templates of every reader directory, the allow-listed files among them' do
      files = ConversationVisibilityGuard.reader_files

      expect(files.size).to be > 500
      expect(files).to include('app/controllers/application_controller.rb', 'app/views/layouts/application.html.erb',
                               'app/jobs/application_job.rb', 'app/channels/application_cable/channel.rb',
                               *ConversationVisibilityGuard::OWNERS.keys)
      expect(files.grep(%r{\Aapp/(?:models|policies)/})).to be_empty
      left_out = ConversationVisibilityGuard.files(%w[app]) - files
      expect(left_out).to include('app/models/conversation.rb', 'app/policies/conversation_policy.rb')
      ConversationVisibilityGuard::READER_DIRECTORIES.each do |directory|
        expect(files.grep(%r{\A#{directory}/})).not_to be_empty, "no file read under #{directory}"
      end
      expect(files.grep(/\.rb\z/).size).to be > 100
      expect(files.grep(/\.erb\z/).size).to be > 100
    end

    # Every directory of today is named in one of the two lists, so the real tree cannot
    # tell "all of app/ but the keepers" from "the named directories". A made-up tree can.
    it 'reads a directory under app/ that nobody named, and never the keepers of the rule' do
      Dir.mktmpdir do |directory|
        root = Pathname(directory)
        %w[app/forms/new_reader.rb app/models/conversation.rb app/policies/conversation_policy.rb
           app/views/things/show.html.erb app/assets/stylesheets/things.css].each do |file|
          root.join(file).dirname.mkpath
          root.join(file).write("# nothing\n")
        end

        expect(ConversationVisibilityGuard.reader_files(root: root))
          .to eq(%w[app/forms/new_reader.rb app/views/things/show.html.erb])
      end
    end

    it 'reads all of app/ for broadcasts, and knows the files that name a model' do
      files = ConversationVisibilityGuard.files(%w[app])
      naming = files.select { |file| ConversationVisibilityGuard.in_file(:mentions, file).any? }

      expect(files.size).to be > 1000
      expect(files).to include('app/models/user.rb', 'app/views/layouts/application.html.erb')
      expect(naming).to include('app/models/conversation.rb', 'app/models/conversation_post.rb',
                                'app/services/user_data_exports/registry.rb')
    end

    it 'reads files in each of the closed directories' do
      files = ConversationVisibilityGuard.files(ConversationVisibilityGuard::CLOSED_DIRECTORIES)

      ConversationVisibilityGuard::CLOSED_DIRECTORIES.each do |directory|
        expect(files.grep(%r{\A#{directory}/})).not_to be_empty, "no file read under #{directory}"
      end
      expect(files).to include('app/services/lalabase/tools/base.rb', 'app/controllers/admin/users_controller.rb')
      expect(files.grep(%r{\Aapp/views/admin/.+\.erb\z})).not_to be_empty
    end
  end

  describe 'the allow-list check' do
    it 'reports an entry for a file that is gone and an entry without a finding left, and no other' do
      owners = ConversationVisibilityGuard::OWNERS.merge(
        'app/services/no_such_reader.rb' => 'made up: the file does not exist',
        'app/controllers/application_controller.rb' => 'made up: the file reads no conversation'
      )

      expect(ConversationVisibilityGuard.stale(owners)).to eq(
        ['app/services/no_such_reader.rb: no such file', 'app/controllers/application_controller.rb: no finding left']
      )
    end
  end

  describe 'how a source is read' do
    it 'raises on a source that does not parse instead of reading it as clean' do
      expect { ConversationVisibilityGuard.reads("def broken(\n") }.to raise_error(ArgumentError, /does not parse/)
      expect { ConversationVisibilityGuard.reads("<% if open %>\n", erb: true, name: 'a.html.erb') }
        .to raise_error(ArgumentError, /a\.html\.erb does not parse/)
      expect { ConversationVisibilityGuard.mentions('class') }.to raise_error(ArgumentError, /does not parse/)
      expect { ConversationVisibilityGuard.broadcasts('foo(') }.to raise_error(ArgumentError, /does not parse/)
      expect { ConversationVisibilityGuard.rule_words('end') }.to raise_error(ArgumentError, /does not parse/)
    end

    it 'reads the Ruby of every kind of tag of a template, on its own line' do
      template = <<~ERB
        <h1>Conversation.all is text here</h1>
        <% if open %><p>one</p><% else %><p>two</p><% end %>
        <%= yield :head %>
        <%# Conversation.all %>
        <%% Conversation.all %>
        <%== Conversation.count -%>
        <%- rows = ConversationPost
                     .where(kind: 'message') -%>
        <p><%= Conversation.find(id).title %></p>
      ERB

      expect(ConversationVisibilityGuard.reads(template, erb: true)).to eq(
        [[6, 'Conversation.count'], [7, 'ConversationPost.where'], [9, 'Conversation.find']]
      )
    end

    it 'does not read a template as plain Ruby, nor plain Ruby as a template' do
      expect(shapes('<%= Conversation.count %>', erb: true)).to eq(['Conversation.count'])
      expect(shapes('Conversation.count', erb: true)).to be_empty
    end
  end

  describe 'what counts as a read past the rule' do
    it 'flags every class-level read of a model' do
      reads = {
        'Conversation.where(id: 1)' => 'Conversation.where',
        'ConversationPost.find(id)' => 'ConversationPost.find',
        'ConversationParticipant.pluck(:user_id)' => 'ConversationParticipant.pluck',
        'Conversation.all' => 'Conversation.all',
        '::Conversation.find_by(id: id)' => 'Conversation.find_by',
        "Conversation\n  .where(archived: false)\n" => 'Conversation.where',
        "ConversationPost\n  .joins(:conversation)\n" => 'ConversationPost.joins',
        'Conversation.joins(:creator)' => 'Conversation.joins',
        'stream_for Conversation.find(params[:id])' => 'Conversation.find',
        'ConversationPost.count' => 'ConversationPost.count',
        'Conversation.exists?(id: id)' => 'Conversation.exists?',
        'Conversation.order(:created_at)' => 'Conversation.order',
        'Conversation.unscoped' => 'Conversation.unscoped',
        'Conversation.includes(:creator)' => 'Conversation.includes',
        'Conversation.find_or_create_by(title: title)' => 'Conversation.find_or_create_by',
        'Conversation.send(:where, id: 1)' => 'Conversation.send',
        'Conversation::where(id: 1)' => 'Conversation.where',
        'Conversation&.first' => 'Conversation.first',
        'policy_scope(Conversation.all)' => 'Conversation.all',
        "label = \"\#{Conversation.count} conversations\"" => 'Conversation.count',
        'Conversation.transaction { ConversationPost.where(id: ids).to_a }' => 'ConversationPost.where',
        'rows = Conversation' => 'bare Conversation',
        '@model = ::ConversationPost' => 'bare ConversationPost',
        "def model\n  Conversation\nend\n" => 'bare Conversation',
        "def model\n  return ConversationParticipant\nend\n" => 'bare ConversationParticipant',
        'MODELS = [Conversation].freeze' => 'bare Conversation',
        'sources = { posts: ConversationPost }' => 'bare ConversationPost',
        'lookup(Conversation => :title)' => 'bare Conversation',
        'rows = [model: Conversation]' => 'bare Conversation',
        "def each_option\n  yield model: ConversationPost\nend\n" => 'bare ConversationPost',
        "def each_model\n  yield Conversation\nend\n" => 'bare Conversation',
        'load_all(&Conversation)' => 'bare Conversation'
      }

      aggregate_failures do
        reads.each { |source, shape| expect(shapes(source)).to eq([shape]), "#{source}: #{shapes(source).inspect}" }
      end
    end

    it 'flags SQL text that names one of the three tables behind JOIN or FROM' do
      reads = {
        "sql = 'SELECT id FROM conversations WHERE organisation_id = ?'" => 'conversations',
        "sql = <<~SQL\n  SELECT posts.id FROM posts\n  JOIN conversation_posts ON conversation_posts.id = posts.id\nSQL\n" =>
          'conversation_posts',
        "sql = <<~SQL.squish\n  SELECT user_id FROM\n    conversation_participants\nSQL\n" => 'conversation_participants',
        "scope.joins('LEFT JOIN conversation_posts ON conversation_posts.user_id = users.id')" => 'conversation_posts',
        "sql = 'select 1 from public.conversation_participants'" => 'conversation_participants',
        %(sql = 'INNER JOIN "conversations" ON "conversations"."id" = 1') => 'conversations',
        %(sql = 'DELETE FROM "public"."conversations"') => 'conversations',
        'sql = %(SELECT 1 FROM conversations)' => 'conversations',
        "sql = 'SELECT id FROM ' \\\n      'conversations'\n" => 'conversations',
        "sql = \"SELECT 1 FROM conversation_posts WHERE id = '\#{id}'\"" => 'conversation_posts',
        "sql = \"SELECT \#{columns} FROM conversations\#{suffix}\"" => 'conversations',
        'rows = `psql -c "SELECT 1 FROM conversations"`' => 'conversations'
      }

      aggregate_failures do
        reads.each do |source, table|
          expect(shapes(source)).to eq(["SQL text naming #{table}"]), "#{source}: #{shapes(source).inspect}"
        end
      end
    end

    it 'flags a read in a template' do
      expect(shapes('<%= Conversation.count %>', erb: true)).to eq(['Conversation.count'])
      expect(shapes("<ul>\n<% ConversationPost.where(kind: 'message').each do |post| %>\n<% end %>\n</ul>", erb: true))
        .to eq(['ConversationPost.where'])
      expect(shapes(%(<%= select_all("SELECT 1 FROM conversations") %>), erb: true))
        .to eq(['SQL text naming conversations'])
    end

    it 'names the line of each read, in a broken chain and in a heredoc as well' do
      source = <<~RUBY
        rows = Conversation.visible_to(user)
        # Conversation.all
        posts = ConversationPost
                .where(kind: 'message')
                .includes(:conversation_participants)
        sql = <<~SQL
          SELECT id
          FROM conversations
        SQL
        plain = "SELECT id
                 FROM conversation_posts"
      RUBY

      expect(ConversationVisibilityGuard.reads(source)).to eq(
        [[3, 'ConversationPost.where'], [5, 'includes naming conversation_participants'],
         [8, 'SQL text naming conversations'], [11, 'SQL text naming conversation_posts']]
      )
    end

    it 'lets the rule, writes, names, arguments and type tests pass' do
      others = [
        'Conversation.visible_to(user)',
        'Conversation.visible_to(user).where(archived: false).order(:created_at)',
        "Conversation\n  .visible_to(user)\n  .find(params[:id])\n",
        'ConversationPost.visible_to(user).count',
        'policy_scope(Conversation)',
        'policy_scope(Conversation).find(params[:id])',
        'authorize Conversation',
        'authorize Conversation, :create?',
        'record.is_a?(Conversation)',
        'record.class == ConversationPost',
        'render Row.new(model: Conversation, user: user)',
        "case record\nwhen Conversation, ConversationPost then record.id\nend\n",
        'Conversation.new(title: t)',
        'Conversation.create(title: t)',
        'ConversationPost.create!(conversation: conversation, body: body)',
        'Conversation.transaction { conversation.save! }',
        'ConversationPost::KINDS',
        '::ConversationPost::KINDS.include?(kind)',
        'Conversation.model_name.human',
        'Conversation.human_attribute_name(:title)',
        'ConversationParticipant.table_name',
        'Conversation.name',
        "# Conversation.where(id: 1)\n",
        "=begin\nConversation.all\n=end\n",
        "note = 'Conversation.where(id: 1)'",
        'conversation.title',
        'conversation.conversation_posts.order(:created_at)',
        '@conversation = conversations.first',
        'Conversations.enabled?',
        'ConversationPolicy.new(user, record)',
        'ConversationsController',
        'Assistant::Conversation.all',
        'Chat.where(conversation: true)'
      ]

      aggregate_failures do
        others.each { |source| expect(shapes(source)).to be_empty, "found, but is no read: #{source}" }
      end
    end

    it 'lets SQL text about other tables pass' do
      others = [
        "sql = 'LEFT JOIN chats ON chats.id = chatposts.chat_id'",
        "sql = 'SELECT 1 FROM conversations_archive'",
        "sql = 'SELECT 1 FROM conversation_posts_2025'",
        "sql = 'SELECT 1 FROM assistant_conversations'",
        "sql = 'UPDATE chats SET conversations = 1'",
        "sql = \"SELECT 1 FROM \#{table}\"",
        "sql = \"SELECT 1 FROM \#{inner} conversations\"",
        "# SELECT 1 FROM conversations\n",
        "scope.from('conversations')",
        "t('views.conversations.index.title')"
      ]

      aggregate_failures do
        others.each { |source| expect(shapes(source)).to be_empty, "found, but names no table: #{source}" }
      end
    end
  end

  describe 'what counts as a read through an association' do
    it 'flags the loaded target and a preload or a join behind the rule' do
      expect(shapes('record.association(:conversation_posts).target'))
        .to eq(['association naming conversation_posts'])
      expect(shapes('association(:conversation_participants).reset'))
        .to eq(['association naming conversation_participants'])
      expect(shapes('project.association(:conversations).loaded?')).to eq(['association naming conversations'])
      expect(shapes('Conversation.visible_to(u).includes(:conversation_posts)'))
        .to eq(['includes naming conversation_posts'])
      expect(shapes('scope.preload(conversation_participants: :user)'))
        .to eq(['preload naming conversation_participants'])
      expect(shapes('Project.joins(:conversations)')).to eq(['joins naming conversations'])
      expect(shapes('<%= Project.joins(:conversations).count %>', erb: true)).to eq(['joins naming conversations'])
      expect(shapes("<% rows = scope\n  .includes(:creator, :conversation_posts) %>", erb: true))
        .to eq(['includes naming conversation_posts'])
    end

    %w[includes preload eager_load joins left_joins left_outer_joins references].each do |method|
      {
        ':conversation_posts' => 'conversation_posts',
        "'conversation_participants'" => 'conversation_participants',
        '[:creator, :conversations]' => 'conversations',
        '%i[conversation_posts creator]' => 'conversation_posts',
        'conversation: :conversation_posts' => 'conversation_posts',
        '{ creator: { conversations: :creator } }' => 'conversations',
        ":creator,\n  conversation_participants: %i[user]" => 'conversation_participants',
        '*[:conversation_posts]' => 'conversation_posts',
        ':conversation_posts, conversations: []' => 'conversation_posts, conversations'
      }.each do |arguments, named|
        it "flags #{method} with #{arguments.inspect}" do
          expect(shapes("scope.#{method}(#{arguments})")).to eq(["#{method} naming #{named}"])
          expect(shapes("#{method}(#{arguments})")).to eq(["#{method} naming #{named}"])
        end
      end

      it "does not mistake text or another association for #{method} of a conversation" do
        expect(shapes("scope.#{method}(:creator)")).to be_empty
        expect(shapes("#{method}(:creator)")).to be_empty
        expect(shapes("scope.#{method}(:conversation, :conversation_post_drafts)")).to be_empty
        expect(shapes("# scope.#{method}(:conversation_posts)\n")).to be_empty
        expect(shapes("note = 'scope.#{method}(:conversation_posts)'")).to be_empty
      end
    end

    it 'lets other calls that name the word pass' do
      expect(shapes('scope.where(conversation_posts: { kind: kind })')).to be_empty
      expect(shapes('scope.order(:conversations)')).to be_empty
      expect(shapes('delegate :conversation_posts, to: :conversation')).to be_empty
    end
  end

  describe 'what counts as the project or an admin role in the rule' do
    def model_with(body)
      <<~RUBY
        class Conversation < ApplicationRecord
          belongs_to :project, optional: true

          scope :visible_to, lambda { |user|
            #{body}
          }

          def visible_to?(user)
            self.class.visible_to(user).exists?(id: id)
          end
        end
      RUBY
    end

    def words(source, **bodies)
      ConversationVisibilityGuard.rule_words(source, **bodies)
    end

    it 'finds the words in the body of the scope, in code and in SQL text' do
      expect(words(model_with('where(project_id: ids)'), scopes: %i[visible_to]))
        .to eq([[5, 'project_id in the scope visible_to']])
      expect(words(model_with('all if user.account_admin_in?(organisation)'), scopes: %i[visible_to]))
        .to eq([[5, 'account_admin_in in the scope visible_to']])
      expect(words(model_with("where('id IN (SELECT conversation_id FROM projects)')"), scopes: %i[visible_to]))
        .to eq([[5, 'projects in the scope visible_to']])
      expect(words(model_with('where(id: Project.readable_by(user).select(:id))'), scopes: %i[visible_to]))
        .to eq([[5, 'Project in the scope visible_to']])
      expect(words(model_with('where(id: ids).or(where(ACCOUNT_ADMIN => true))'), scopes: %i[visible_to]))
        .to eq([[5, 'ACCOUNT_ADMIN in the scope visible_to']])
    end

    it 'reads the scope in either spelling of its lambda' do
      source = "scope :visible_to, ->(user) { where(project_id: user.project_ids) }\n"

      expect(words(source, scopes: %i[visible_to]))
        .to eq([[1, 'project_id in the scope visible_to'], [1, 'project_ids in the scope visible_to']])
    end

    it 'reads the named methods' do
      source = <<~RUBY
        def visible_to?(user)
          project.member?(user)
        end

        def visible_participants
          User.where(id: organisation.account_admins)
        end
      RUBY

      expect(words(source, methods: %i[visible_to? visible_participants])).to eq(
        [[2, 'project in the method visible_to?'], [6, 'account_admins in the method visible_participants']]
      )
    end

    it 'reads a whole file when asked to' do
      policy = <<~RUBY
        # no admin role and no project opens a conversation
        class ConversationPolicy < ApplicationPolicy
          def show?
            record.visible_to?(user) || user.account_admin_in?(record.organisation)
          end
        end
      RUBY

      expect(words(policy, whole: true)).to eq([[4, 'account_admin_in in the file']])
      expect(words(policy.sub(' || user.account_admin_in?(record.organisation)', ''), whole: true)).to be_empty
    end

    it 'lets the words pass in a comment, and outside the named bodies' do
      body = "# no project_id and no account_admin_in? here\n    where(id: ids) # not the project\n"

      expect(words(model_with(body), scopes: %i[visible_to], methods: %i[visible_to?])).to be_empty
      expect(words("scope :visible_to, ->(user) {\n=begin\nproject\n=end\n  where(id: ids)\n}\n", scopes: %i[visible_to]))
        .to be_empty
    end

    it 'is red for a source without the scope or without the method' do
      expect(words("class Conversation < ApplicationRecord\nend\n", scopes: %i[visible_to]))
        .to eq([[1, 'no scope visible_to found']])
      expect(words(model_with('where(id: ids)').sub(':visible_to', ':readable_by'), scopes: %i[visible_to]))
        .to eq([[1, 'no scope visible_to found']])
      expect(words(model_with('where(id: ids)'), scopes: %i[visible_to], methods: %i[visible_to? visible_participants]))
        .to eq([[1, 'no method visible_participants found']])
      expect(words("def self.visible_to?(user)\n  true\nend\n", methods: %i[visible_to?]))
        .to eq([[1, 'no method visible_to? found']])
      expect(words("scope :visible_to\n", scopes: %i[visible_to])).to eq([[1, 'no scope visible_to found']])
    end

    it 'is red for a file that is gone, and for a file of the tree without the body' do
      rule_files = {
        'app/models/no_such_model.rb' => { whole: true },
        'app/models/application_record.rb' => { scopes: %i[visible_to], whole: true }
      }

      expect(ConversationVisibilityGuard.rule_findings(rule_files)).to eq(
        ['app/models/no_such_model.rb: no such file', 'app/models/application_record.rb:1: no scope visible_to found']
      )
    end
  end

  describe 'what counts as a Turbo broadcast about a conversation' do
    def calls(source, **options)
      ConversationVisibilityGuard.broadcasts(source, **options).map(&:last)
    end

    it 'flags a broadcast in a source that names a model' do
      aggregate_failures do
        expect(calls("class ConversationPost < ApplicationRecord\n  after_create_commit -> { broadcast_append_to conversation }\nend\n"))
          .to eq(['broadcast_append_to'])
        expect(calls("post = ConversationPost.create!(body: body)\npost.broadcast_replace_later_to(conversation)\n"))
          .to eq(['broadcast_replace_later_to'])
        expect(calls("class ConversationParticipant < ApplicationRecord\n  broadcasts_to :conversation\nend\n"))
          .to eq(['broadcasts_to'])
        expect(calls("authorize Conversation\nTurbo::StreamsChannel.broadcast_update_to(stream, target: 'list', html: html)\n"))
          .to eq(['broadcast_update_to'])
        expect(calls("<% ::Conversation.visible_to(user) %>\n<% row.broadcast_refresh %>", erb: true))
          .to eq(['broadcast_refresh'])
      end
    end

    %w[append prepend replace update before after remove action refresh render stream].each do |stem|
      it "flags broadcast_#{stem} and its three variants" do
        ['', '_to', '_later', '_later_to'].each do |suffix|
          expect(calls("Conversation.new\nrow.broadcast_#{stem}#{suffix}(stream)")).to eq(["broadcast_#{stem}#{suffix}"])
        end
      end
    end

    it 'flags the declarations of a model' do
      %w[broadcasts broadcasts_to broadcasts_refreshes broadcasts_refreshes_to].each do |declaration|
        expect(calls("class Conversation < ApplicationRecord\n  #{declaration} :organisation\nend\n")).to eq([declaration])
      end
    end

    it 'names the line of each broadcast' do
      source = "class Conversation < ApplicationRecord\n  broadcasts_refreshes\n\n  def tell\n    self\n      .broadcast_replace_to(self)\n  end\nend\n"

      expect(ConversationVisibilityGuard.broadcasts(source)).to eq([[2, 'broadcasts_refreshes'], [6, 'broadcast_replace_to']])
    end

    it 'lets the same call pass in a source that names no model' do
      expect(calls('broadcast_append_to conversation')).to be_empty
      expect(calls("conversation.broadcast_replace_later_to(conversation)\n")).to be_empty
      expect(calls("class Ticket < ApplicationRecord\n  broadcasts_to :project\nend\n")).to be_empty
      expect(calls("Conversations.enabled?\nTurbo::StreamsChannel.broadcast_update_to(stream, html: html)\n")).to be_empty
      expect(calls("# Conversation\nrow.broadcast_refresh\n")).to be_empty
    end

    it "lets the application's own broadcast methods pass, and text" do
      expect(calls("Conversation.new\nBroadcastService.broadcast_badge_update(user)\n")).to be_empty
      expect(calls("Conversation.new\nbroadcast_creation\nbroadcast_updated(row)\n")).to be_empty
      expect(calls("Conversation.new\nrow.broadcast_append_later_to_everybody(stream)\n")).to be_empty
      expect(calls("Conversation.new\nrow.rebroadcast_append_to(stream)\n")).to be_empty
      expect(calls("Conversation.new\n# row.broadcast_append_to(stream)\nnote = 'broadcasts_to :conversation'\n")).to be_empty
      expect(calls("class Conversation < ApplicationRecord\n  def broadcast_update_to(stream); end\nend\n")).to be_empty
    end
  end

  describe 'what counts as naming a model' do
    def names(source, **options)
      ConversationVisibilityGuard.mentions(source, **options).map(&:last)
    end

    it 'flags any mention, in any position, the rule included' do
      aggregate_failures do
        expect(names('ConversationPost')).to eq(['ConversationPost'])
        expect(names('::Conversation')).to eq(['Conversation'])
        expect(names('policy_scope(Conversation)')).to eq(['Conversation'])
        expect(names('Conversation.visible_to(user)')).to eq(['Conversation'])
        expect(names('ConversationParticipant::ROLES')).to eq(['ConversationParticipant'])
        expect(names("case record\nwhen Conversation then 1\nend\n")).to eq(['Conversation'])
        expect(names('record.is_a?(::ConversationPost)')).to eq(['ConversationPost'])
        expect(names("class Conversation < ApplicationRecord\nend\n")).to eq(['Conversation'])
        expect(names('<td><%= ConversationPost.model_name.human %></td>', erb: true)).to eq(['ConversationPost'])
        expect(ConversationVisibilityGuard.mentions("x = 1\ny = [Conversation,\n     ConversationPost]\n"))
          .to eq([[2, 'Conversation'], [3, 'ConversationPost']])
      end
    end

    it 'lets the switch, other constants, a variable and text pass' do
      others = [
        'Conversations.enabled?',
        'ConversationPolicy.new(user, record)',
        'ConversationsController',
        'Assistant::Conversation.new',
        'ConversationPostsHelper',
        "# Conversation.visible_to(user)\n",
        "label = 'Conversation'",
        'kind = :Conversation',
        'conversation.title',
        'conversation_posts.each { |conversation_post| conversation_post }',
        'Chat.where(conversation: true)'
      ]

      aggregate_failures do
        others.each { |source| expect(names(source)).to be_empty, "found, but names no model: #{source}" }
        expect(names('<p>Conversation</p><%# ConversationPost %><%= conversation.title %>', erb: true)).to be_empty
      end
    end
  end
end

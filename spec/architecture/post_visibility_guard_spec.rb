# frozen_string_literal: true

require 'rails_helper'
require 'prism'

# What: code that shows, searches, summarises or mails comments reaches them only
#   through Post.readable_by (one reader) or Post.public_posts (every reader of the
#   ticket), never through a bare ticket.posts or a bare JOIN posts.
# Why: the rule for private comments lived in PostPolicy, and five readers forgot it
#   (timeline, search, activity excerpt, summary, AI answer; audit of 26.09.2026),
#   two more turned up while fixing them (the mail's previous comment, the fanout).
#   Each was a plain ticket.posts. A rule that has to be remembered at every read
#   is not a rule, so the bare read is what this guard refuses.
module PostVisibilityGuard
  DIRECTORIES = %w[controllers services queries mailers components views presenters jobs helpers].freeze

  # Reads that are safe by construction: the rule itself, the audience-wide scope,
  # one record by id (the caller authorizes it; Pundit's tripwire enforces that in
  # controllers) and writes
  SAFE_CHAIN = /\A\.(?:readable_by|public_posts|find|find_by|build|new)\b|\A\.create!/

  # Shrink-only: every entry names why the bare read is safe or when it goes away.
  # An entry without a finding left fails too, so a fixed file must leave the list.
  ALLOWED = {
    'app/services/assistant/analysis_sources.rb' =>
      'loads the cited posts by id and checks each with PostPolicy#show? before use',
    'app/presenters/ticket_description_state.rb' =>
      "reads only the viewer's own posts (where user_id: current_user.id)",
    'app/services/embeddings/content_types.rb' =>
      'indexing, not reading: the join feeds an opt-in that says posts.is_private = FALSE'
  }.freeze

  STRING_LITERAL = /'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/

  # [line number, text] of every bare read in one file's source
  def self.findings(source, erb: false)
    lines = source.lines
    bare_reads = lines.each_with_index.filter_map do |line, index|
      next if line.match?(/\A\s*(?:#|<%#)/)

      [index + 1, line.strip] if bare_association?(line, lines[index + 1]) || bare_join?(line)
    end
    (bare_reads + preloaded_posts(source, erb: erb)).uniq.sort_by(&:first)
  end

  # ticket.posts not followed by a safe call, on this line or, for a chain broken
  # after .posts, on the next one. association(:posts) reads the loaded target,
  # which is how the timeline used to skip every filter.
  def self.bare_association?(line, next_line)
    code = line.gsub(STRING_LITERAL, '""')
    return true if code.include?('association(:posts)')

    code.to_enum(:scan, /\.posts\b/).any? do
      rest = Regexp.last_match.post_match.strip
      rest = next_line.to_s.strip if rest.empty?
      !rest.match?(SAFE_CHAIN)
    end
  end

  # A SQL join onto posts must narrow the rows itself (posts.id IN a readable set)
  def self.bare_join?(line)
    line.match?(/JOIN\s+posts\b/i) && !line.include?('posts.id IN (')
  end

  # Parse calls rather than matching a line: preload arguments can span lines,
  # nest hashes or use symbol arrays. Literal text and comments are not calls.
  # Dynamic association lists still need review; this is a static tripwire.
  def self.preloaded_posts(source, erb: false)
    ruby = source
    if erb
      ruby = source.gsub(/[^\n]/, ' ')
      source.to_enum(:scan, /<%(?![#%])[=-]?(.*?)-?%>/m).each do
        match = Regexp.last_match
        ruby[match.begin(1), match[1].length] = match[1]
      end
    end

    nodes = [Prism.parse(ruby).value]
    findings = []
    until nodes.empty?
      node = nodes.pop
      if node.is_a?(Prism::CallNode) && %i[includes preload eager_load].include?(node.name) &&
         posts_argument?(node.arguments)
        line = node.message_loc.start_line
        findings << [line, source.lines[line - 1].strip]
      end
      nodes.concat(node.compact_child_nodes)
    end
    findings
  end

  def self.posts_argument?(node)
    case node
    when Prism::SymbolNode, Prism::StringNode
      node.unescaped == 'posts'
    when Prism::ArgumentsNode, Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::AssocNode
      node.compact_child_nodes.any? { |child| posts_argument?(child) }
    else
      false
    end
  end

  def self.files
    DIRECTORIES.flat_map { |dir| Dir[Rails.root.join("app/#{dir}/**/*.{rb,erb}")] }
               .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort
  end
end

RSpec.describe 'Comment reads go through Post.readable_by', type: :architecture do
  it 'finds no bare reads or post preloads outside the allow list' do
    offenders = PostVisibilityGuard.files.reject { |file| PostVisibilityGuard::ALLOWED.key?(file) }
                                   .flat_map do |file|
      PostVisibilityGuard.findings(File.read(Rails.root.join(file)), erb: file.end_with?('.erb')).map { |number, text| "#{file}:#{number}: #{text}" }
    end

    expect(offenders).to be_empty,
                         "These read comments without the visibility rule:\n#{offenders.join("\n")}\n\n" \
                         'Use ticket.posts.readable_by(user, organisation) for what one person sees, ' \
                         'ticket.posts.public_posts for what every reader of the ticket sees ' \
                         '(an excerpt, a summary, an AI answer).'
  end

  it 'keeps no allow-list entry that no longer has a finding' do
    stale = PostVisibilityGuard::ALLOWED.keys.select do |file|
      path = Rails.root.join(file)
      !path.exist? || PostVisibilityGuard.findings(path.read, erb: file.end_with?('.erb')).empty?
    end

    expect(stale).to be_empty, "Remove these from PostVisibilityGuard::ALLOWED, they are clean now:\n#{stale.join("\n")}"
  end

  describe 'what counts as a bare read' do
    def bare?(source, **options)
      PostVisibilityGuard.findings(source, **options).any?
    end

    it 'flags reads that take every post' do
      expect(bare?("ticket.posts.each { |post| post }\n")).to be(true)
      expect(bare?("@ticket.posts.includes(:user).order(:created_at)\n")).to be(true)
      expect(bare?("ticket.posts.visible_to(user)\n")).to be(true)
      expect(bare?("@ticket.posts\n")).to be(true)
      expect(bare?("@ticket.association(:posts).target\n")).to be(true)
      expect(bare?("sql = 'LEFT JOIN posts ON posts.ticket_id = tickets.id'\n")).to be(true)
    end

    %w[includes preload eager_load].each do |method|
      [':posts', 'posts: :user', '{ posts: %i[user visible_to_user] }',
       ':creator,\n posts: %i[user rich_text_content]', 'ticket: :posts',
       'tickets: { posts: :user }'].each do |arguments|
        it "flags #{method} with #{arguments}" do
          expect(bare?("Ticket.#{method}(#{arguments.gsub('\\n', "\n")})")).to be(true)
        end
      end

      it "flags #{method} in an ERB expression" do
        expect(bare?("<div>\n<%= Ticket.#{method}(posts: :user) %>\n</div>", erb: true)).to be(true)
      end

      it "does not mistake text or other associations for #{method} of posts" do
        expect(bare?("# Ticket.#{method}(:posts)\n")).to be(false)
        expect(bare?("message = 'Ticket.#{method}(posts: :user)'\n")).to be(false)
        expect(bare?("Post.#{method}(:post_documents, :user)\n")).to be(false)
        expect(bare?("Chat.#{method}(:chatposts)\n")).to be(false)
        expect(bare?("ticket.posts.readable_by(user, org).#{method}(:user)\n")).to be(false)
      end
    end

    it 'lets the rule, the audience-wide scope, lookups by id and writes pass' do
      expect(bare?("ticket.posts.readable_by(user, organisation)\n")).to be(false)
      expect(bare?("@ticket.posts\n  .public_posts\n")).to be(false)
      expect(bare?("@ticket.posts.find(params[:id])\n")).to be(false)
      expect(bare?("ticket.posts.create!(content: body)\n")).to be(false)
      expect(bare?("\"LEFT JOIN posts ON posts.ticket_id = tickets.id AND posts.id IN (\#{ids})\"\n")).to be(false)
    end

    it 'ignores comments and text that only mentions posts' do
      expect(bare?("# ticket.posts used to be read here\n")).to be(false)
      expect(bare?("t('views.organisations.posts.form.title')\n")).to be(false)
      expect(bare?("@chat.chatposts.each { |post| post }\n")).to be(false)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'
require 'prism'

# What: on the two token surfaces (the API controllers and the tools of
#   Lalabase::Tools) a single ticket is found through Tickets::ReadableForToken,
#   by way of with_readable_ticket, with_readable_ticket_number or readable_tickets.
#   A lookup that starts at the Ticket class or at a tickets association and goes
#   past that owner is refused.
# Why: the owner joins the policy scope and the token's reach. A lookup past it
#   skips at least one of them, and the result reads as a working endpoint: a
#   ticket out of the token's reach comes back as a ticket. A rule that has to be
#   remembered at every lookup is not a rule.
# Scope: only those two trees. Elsewhere, under app/services/people and in the time
#   lists, the same words mean something else.
# How: parsed with Prism, so a chain split across lines is one chain, and comments
#   and strings are not calls.
# ⚠️ A tripwire, not a proof. A receiver held in a variable is not seen
#   (scope = project.tickets; scope.find(id)), nor a class picked at run time
#   (viewable_type.constantize.find), nor an association under another name
#   (ticket.subtasks). Those are for the person who reads the diff.
module TicketTokenLookupGuard
  ROOTS = %w[app/controllers/api app/services/lalabase/tools].freeze

  # Each returns one ticket, or tells whether it exists.
  LOOKUPS = %i[find take take! sole exists?].freeze
  # Each leaves the rows the policy scope would have bound, or locks what no gate chose.
  ESCAPES = %i[lock unscoped].freeze
  # A where on one of these addresses a ticket rather than building a list.
  ADDRESS_KEYS = %w[id number].freeze
  ADDRESS_IN_SQL = /\b(?:id|number)\b/
  # The policy scope alone lacks the token's reach, so it does not gate a lookup.
  SCOPES = %i[policy_scope policy_scope!].freeze

  RECENT_ACTIVITY = 'app/services/lalabase/tools/recent_activity.rb'

  # Shrink-only. `code` names the one call that may stay: anything else in the same
  # file is still a finding. An entry whose call is gone fails too.
  ALLOWED = {
    'app/controllers/api/v1/tickets_controller.rb' => {
      code: 'project.tickets.lock.find(ticket.id)',
      reason: 'the ticket already passed with_readable_ticket; this re-reads it under a lock ' \
              'to answer. Policy scope plus FOR UPDATE would be a different query'
    },
    RECENT_ACTIVITY => {
      code: 'Ticket.where(id: ids)',
      reason: 'on no token surface: assistant set only, held by a test below. The ids come ' \
              'from rows Activities::VisibleTo already gated by area and reach'
    }
  }.freeze

  # [line number, text] of every lookup past the owner in one file's source
  def self.findings(source)
    result = Prism.parse(source)
    raise ArgumentError, "unparsable source: #{result.errors.first&.message}" unless result.success?

    lines = source.lines
    calls(result.value).filter_map do |node, untenanted|
      next unless past_the_owner?(node, untenanted)

      line = node.message_loc.start_line
      [line, lines[line - 1].strip]
    end.uniq.sort_by(&:first)
  end

  # Every call, each with whether it sits inside a without_tenant block
  def self.calls(root)
    found = []
    pending = [[root, false]]
    until pending.empty?
      node, untenanted = pending.pop
      call = node.is_a?(Prism::CallNode)
      found << [node, untenanted] if call
      inside = untenanted || (call && node.name == :without_tenant)
      node.compact_child_nodes.each { |child| pending << [child, inside] }
    end
    found
  end

  def self.past_the_owner?(node, untenanted)
    return false unless tickets_at_root?(node)

    untenanted || lookup?(node)
  end

  def self.lookup?(node)
    name = node.name
    LOOKUPS.include?(name) || ESCAPES.include?(name) || name.to_s.start_with?('find_by') ||
      (name == :where && addressed?(node.arguments))
  end

  # Walks down the receivers: a chain that reached the owner has its call at the
  # root, readable_tickets(...) or Tickets::ReadableForToken, so it never gets here
  # with a Ticket at the bottom.
  def self.tickets_at_root?(node)
    current = node
    while current.is_a?(Prism::CallNode)
      return true if current.name == :tickets
      return scoped_tickets?(current) if SCOPES.include?(current.name)

      current = current.receiver
    end
    ticket_constant?(current)
  end

  def self.scoped_tickets?(node)
    node.arguments&.arguments.to_a.any? { |argument| tickets_at_root?(argument) }
  end

  # Ticket or ::Ticket, not Ticket::TITLE_MAX_LENGTH or Foo::Ticket
  def self.ticket_constant?(node)
    return node.name == :Ticket if node.is_a?(Prism::ConstantReadNode)

    node.is_a?(Prism::ConstantPathNode) && node.parent.nil? && node.name == :Ticket
  end

  def self.addressed?(arguments)
    arguments&.arguments.to_a.any? do |argument|
      case argument
      when Prism::StringNode then argument.unescaped.match?(ADDRESS_IN_SQL)
      when Prism::KeywordHashNode, Prism::HashNode then address_key?(argument)
      else false
      end
    end
  end

  def self.address_key?(hash)
    hash.elements.any? do |element|
      key = element.is_a?(Prism::AssocNode) ? element.key : nil
      key.respond_to?(:unescaped) && ADDRESS_KEYS.include?(key.unescaped)
    end
  end

  def self.files
    ROOTS.flat_map { |root| Dir[Rails.root.join("#{root}/**/*.rb")] }
         .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort
  end

  # The source of one method, found by name, so a neighbour in the file does not count
  def self.method_source(path, name)
    nodes = [Prism.parse(File.read(Rails.root.join(path))).value]
    until nodes.empty?
      node = nodes.pop
      return node.slice if node.is_a?(Prism::DefNode) && node.name == name

      nodes.concat(node.compact_child_nodes)
    end
    raise ArgumentError, "#{path} has no method #{name}"
  end
end

RSpec.describe 'Token surfaces find a single ticket through the owner', :ci_guard, type: :architecture do
  let(:allowed) { TicketTokenLookupGuard::ALLOWED }

  def findings_in(file)
    TicketTokenLookupGuard.findings(File.read(Rails.root.join(file)))
  end

  it 'finds no lookup past Tickets::ReadableForToken outside the allow list' do
    offenders = TicketTokenLookupGuard.files.flat_map do |file|
      findings_in(file).filter_map do |number, text|
        "#{file}:#{number}: #{text}" unless text.include?(allowed.dig(file, :code) || "\0")
      end
    end

    expect(offenders).to be_empty,
                         "These find a ticket past the owner:\n#{offenders.join("\n")}\n\n" \
                         'In a controller use with_readable_ticket or with_readable_ticket_number, ' \
                         'in a tool readable_tickets(context, relation).'
  end

  it 'keeps no allow-list entry whose call is gone' do
    stale = allowed.reject do |file, entry|
      Rails.root.join(file).exist? && findings_in(file).any? { |_number, text| text.include?(entry[:code]) }
    end

    expect(stale.keys).to be_empty, "Remove these from TicketTokenLookupGuard::ALLOWED:\n#{stale.keys.join("\n")}"
  end

  it 'allows two entries at most, each with a reason' do
    expect(allowed.size).to be <= 2
    expect(allowed.values.map { |entry| entry[:reason] }).to all(be_present)
  end

  it 'reads both trees, or the scan proves nothing' do
    expect(TicketTokenLookupGuard.files).to include('app/controllers/api/v1/posts_controller.rb',
                                                    'app/services/lalabase/tools/post_comment.rb')
    expect(TicketTokenLookupGuard.files).to(be_none { |file| file.match?(%r{\Aapp/services/(?!lalabase/tools/)}) })
  end

  it 'keeps recent_activity off the token surface, which is why its entry is safe' do
    expect(Lalabase::Tools::Registry.for(:mcp)).not_to include(Lalabase::Tools::RecentActivity)
  end

  describe 'the owner is really used' do
    let(:concern) { Rails.root.join('app/controllers/concerns/api/v1/readable_ticket.rb').read }
    let(:base_owner) { TicketTokenLookupGuard.method_source('app/services/lalabase/tools/base.rb', :readable_tickets) }

    it 'runs through the REST concern' do
      expect(concern).to include('Tickets::ReadableForToken.call(')
      expect(concern).not_to include('Pundit.policy_scope!')
    end

    it 'runs through the base of the tools' do
      expect(base_owner).to include('Tickets::ReadableForToken.call(')
      expect(base_owner).to include('token: context.token')
      expect(base_owner).not_to include('Pundit.policy_scope!')
    end
  end

  it 'hands the token to every context of an MCP call' do
    source = TicketTokenLookupGuard.method_source('app/services/mcp/tool_call.rb', :context_for)
    built = source.scan('Context.new').size

    expect(built).to be_positive
    expect(source.scan(/\btoken: @token\b/).size).to eq(built)
  end

  describe 'what counts as a lookup past the owner' do
    def past?(source)
      TicketTokenLookupGuard.findings(source).any?
    end

    [
      'Ticket.find(id)', 'Ticket.find_by(id: id)', 'Ticket.find_by!(id: id)', 'Ticket.take',
      'Ticket.where(id: id)', 'Ticket.where(number: number).first', 'Ticket.where("id = ?", id)',
      'Ticket.unscoped', 'Ticket.lock', 'Ticket.lock.find(id)', '::Ticket.find(id)',
      '::Ticket.where(id: id)', 'Ticket.includes(:project).find(id)', 'Ticket.exists?(id)',
      'Ticket.where(organisation_id: org.id).find(id)',
      'ActsAsTenant.without_tenant { Ticket.find(id) }',
      'ActsAsTenant.without_tenant { Ticket.where(organisation_id: org.id).pick(:id) }',
      'ActsAsTenant.without_tenant do ::Ticket.all.to_a end',
      'project.tickets.find(id)', 'project.tickets.find_by(id: id)', 'project.tickets.find_by!(number: 1)',
      'project.tickets.find_by_number(1)', 'project.tickets.lock.find(id)', 'project.tickets.where(id: id)',
      'project&.tickets&.find(id)', '@project.tickets.find(id)', 'context.project.tickets.find_by(id: id)',
      'organisation.tickets.includes(:creator).where(number: 1).take',
      'policy_scope(project.tickets).find(id)', 'Pundit.policy_scope!(user, Ticket).find(id)'
    ].each do |source|
      it("flags #{source}") { expect(past?("#{source}\n")).to be(true) }
    end

    it 'flags a chain split across lines' do
      expect(past?("project\n  .tickets\n  .lock\n  .find(id)\n")).to be(true)
      expect(past?("Ticket\n  .includes(:project)\n  .find_by(id: id)\n")).to be(true)
      expect(past?("Ticket.where(\n  id: id\n)\n")).to be(true)
    end

    it 'names the line of the call, not of the start of the chain' do
      expect(TicketTokenLookupGuard.findings("x = 1\nproject.tickets\n  .find(id)\n")).to eq([[3, '.find(id)']])
    end

    [
      'readable_tickets(context, context.project.tickets).find_by(id: ticket_id)',
      'readable_tickets(context, base).includes(:creator).find(id)',
      'Tickets::ReadableForToken.call(user: u, organisation: o, relation: Ticket).find(id)',
      'Ticket.where(organisation_id: context.organisation.id, project_id: ids)',
      'policy_scope(project.tickets)',
      'filter.ordered(filter.filtered(policy_scope(project.tickets)))',
      'project.tickets.build',
      'authorize project.tickets.build, :create?',
      'context.project.tickets',
      'Ticket.transaction { save }',
      'Ticket::TITLE_MAX_LENGTH',
      'ActsAsTenant.without_tenant { Project.where(id: id).pick(:organisation_id) }',
      'Foo::Ticket.find(id)',
      'ticket.posts.find(id)',
      'tickets = load; tickets.first',
      'scope = project.tickets; scope.find(id)'
    ].each do |source|
      it("passes #{source}") { expect(past?("#{source}\n")).to be(false) }
    end

    it 'ignores comments and text' do
      expect(past?("# Ticket.find(id) used to be here\n")).to be(false)
      expect(past?("project.tickets # .find(id)\n")).to be(false)
      expect(past?("message = 'Ticket.find(id)'\n")).to be(false)
    end

    it 'refuses source it cannot parse instead of calling it clean' do
      expect { TicketTokenLookupGuard.findings("def broken(\n") }.to raise_error(ArgumentError)
    end
  end
end

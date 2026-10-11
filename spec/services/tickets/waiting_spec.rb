# frozen_string_literal: true

require 'rails_helper'

# "Waits" and "holds others up" (doc/ticket_relations_plan.md, revision 4, §5). The status
# names are chosen so that a pooled "done" list gives the wrong answer: "Closed" means done in
# project X and is still open in project Y. Each ticket is judged by its OWN project.
RSpec.describe Tickets::Waiting, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project_x) { new_project }
  let(:project_y) { new_project }
  # A status field whose values never mean done.
  let(:project_without_done) { new_project }
  # No status field at all.
  let(:project_without_status) { new_project }

  before do
    ActsAsTenant.current_tenant = organisation
    status_field(project_x, [['Open', ['is_new']], ['Closed', ['is_closed']], ['Done', ['is_completed']]])
    status_field(project_y, [['Open', ['is_new']], ['Closed', ['is_in_progress']], ['Done', ['is_completed']]])
    status_field(project_without_done, [['Open', ['is_new']], ['Closed', nil]])
  end

  after { ActsAsTenant.current_tenant = nil }

  def new_project
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  def status_field(project, options_list)
    allowed_values = options_list.map do |value, functions|
      entry = { 'value' => value, 'labels' => { 'de' => value } }
      entry['system_functions'] = functions if functions
      entry
    end
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => allowed_values })
  end

  # Setup only, like #link: each create loads its organisation for the belongs_to check,
  # which Prosopite would report from the second record on. What Waiting itself asks stays
  # scanned.
  def ticket(project, status = 'Open')
    attributes = status ? { 'status' => status } : {}
    Prosopite.pause { create(:ticket, project: project, custom_attributes: attributes) }
  end

  def link(source, target, type = :blocks)
    Prosopite.pause { TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type) }
  end

  def waiting_ids(scope = Ticket.all)
    described_class.waiting(scope).pluck(:id)
  end

  def blocking_ids(scope = Ticket.all)
    described_class.blocking(scope).pluck(:id)
  end

  describe '.waiting and .blocking' do
    it 'marks the target as waiting and the source as holding it up' do
      blocker = ticket(project_y)
      waiter = ticket(project_x)
      link(blocker, waiter)

      expect(waiting_ids).to eq([waiter.id])
      expect(blocking_ids).to eq([blocker.id])
    end

    it 'counts precedes like blocks, and neither relates_to nor duplicates' do
      before_ticket = ticket(project_x)
      after_ticket = ticket(project_x)
      related = ticket(project_x)
      duplicate = ticket(project_x)
      link(before_ticket, after_ticket, :precedes)
      link(before_ticket, related, :relates_to)
      link(duplicate, before_ticket, :duplicates)

      expect(waiting_ids).to eq([after_ticket.id])
      expect(blocking_ids).to eq([before_ticket.id])
    end

    it 'drops a blocker that is done in its own project' do
      waiter = ticket(project_y)
      link(ticket(project_x, 'Closed'), waiter)

      expect(waiting_ids).to be_empty
      expect(blocking_ids).to be_empty
    end

    it 'keeps a blocker whose status name means done only in another project' do
      blocker = ticket(project_y, 'Closed')
      waiter = ticket(project_x)
      link(blocker, waiter)

      expect(waiting_ids).to eq([waiter.id])
      expect(blocking_ids).to eq([blocker.id])
    end

    it 'lets a target that is done in its own project wait on nothing and hold nobody up' do
      blocker = ticket(project_y)
      link(blocker, ticket(project_x, 'Closed'))

      expect(waiting_ids).to be_empty
      expect(blocking_ids).to be_empty
    end

    it 'keeps a target whose status name means done only in another project' do
      blocker = ticket(project_x)
      waiter = ticket(project_y, 'Closed')
      link(blocker, waiter)

      expect(waiting_ids).to eq([waiter.id])
      expect(blocking_ids).to eq([blocker.id])
    end

    it 'treats a ticket without a status as not done, at both ends' do
      blocker = ticket(project_x, nil)
      waiter = ticket(project_x, nil)
      link(blocker, waiter)

      expect(waiting_ids).to eq([waiter.id])
      expect(blocking_ids).to eq([blocker.id])
    end

    it 'treats a project without a done value, or without a status field, as never done' do
      blocker = ticket(project_without_done, 'Closed')
      waiter = ticket(project_without_status, 'Done')
      link(blocker, waiter)

      expect(waiting_ids).to eq([waiter.id])
      expect(blocking_ids).to eq([blocker.id])
    end

    it 'judges the blocker by its own project even when the scope only holds the waiting list' do
      blocker = ticket(project_y, 'Closed')
      waiter = ticket(project_x)
      link(blocker, waiter)

      expect(waiting_ids(Ticket.where(project: project_x))).to eq([waiter.id])
      expect(blocking_ids(Ticket.where(project: project_y))).to eq([blocker.id])
    end

    # A project missing from the done values reads as "never done", so only a ticket that IS
    # done in a project outside the scope shows whether the projects come from the tickets
    # involved or from the scope.
    it 'finds the done values of a project that only the other end lives in' do
      waiter = ticket(project_x)
      link(ticket(project_y, 'Done'), waiter)
      blocker = ticket(project_y)
      link(blocker, ticket(project_x, 'Closed'))

      expect(waiting_ids(Ticket.where(project: project_x))).to be_empty
      expect(blocking_ids(Ticket.where(project: project_y))).to be_empty
      expect(described_class.counts_for([waiter.id, blocker.id]).values.uniq).to eq([{ waiting_on: 0, blocking: 0 }])
      expect(described_class.for(waiter)).to be_empty
    end

    # The done values come from project configuration, i.e. from users, and reach the SQL as
    # positional binds. What a second substitution would act on stays a plain value (#889).
    it 'treats status names with quotes, question marks, colons and dollars as plain values' do
      odd = ["Won't fix", 'Done?', 'Wait:ids', ':search', ':1', '?', '$1', '$$x$$', '%s',
             'back\\slash', "x'); DROP TABLE tickets; --"]
      project = new_project
      status_field(project, [['Open', ['is_new']]] + odd.map { |value| [value, ['is_closed']] })
      waiter = ticket(project)
      odd.each { |status| link(ticket(project, status), waiter) }
      open_blocker = ticket(project)
      link(open_blocker, waiter)

      expect(described_class.counts_for([waiter.id])).to eq(waiter.id => { waiting_on: 1, blocking: 0 })
      expect(waiting_ids).to eq([waiter.id])
      expect(described_class.for(waiter).map(&:id)).to eq([open_blocker.id])
    end

    # Review step 2 (30.09.2026): the preparation query dropped the join of includes/eager_load
    # but kept the condition on the joined table, and PostgreSQL answered with a 500.
    {
      'includes with references' => ->(project) { Ticket.includes(:project).references(:projects).where(projects: { id: project.id }) },
      'eager_load' => ->(project) { Ticket.eager_load(:project).where(projects: { id: project.id }) },
      'includes without a condition on its table' => ->(project) { Ticket.includes(:project).where(project_id: project.id) }
    }.each do |form, scope_for|
      it "takes a scope that loads another table and filters on it (#{form})" do
        blocker = ticket(project_y)
        waiter = ticket(project_x)
        link(blocker, waiter)

        expect(described_class.waiting(scope_for.call(project_x)).map(&:id)).to eq([waiter.id])
        expect(described_class.blocking(scope_for.call(project_y)).map(&:id)).to eq([blocker.id])
      end
    end

    # The done values must come from every candidate of the scope, not from the page a limit
    # or offset cuts out of it: the page is taken AFTER the waiting condition.
    it 'reads the done values beyond the limit of the scope' do
      ticket(project_x)
      waiter = ticket(project_x)
      link(ticket(project_y, 'Done'), waiter)

      expect(waiting_ids(Ticket.where(project: project_x).order(:number).limit(1))).to be_empty
    end

    it 'narrows the given scope and keeps its order' do
      blocker = ticket(project_x)
      first = ticket(project_x)
      second = ticket(project_x)
      link(blocker, first)
      link(blocker, second)

      scope = Ticket.where(id: [first.id, second.id]).order(number: :desc)

      expect(described_class.waiting(scope).pluck(:id)).to eq([second.id, first.id])
    end
  end

  describe '.counts_for' do
    it 'counts tickets, not edges' do
      blocker = ticket(project_x)
      waiter = ticket(project_x)
      link(blocker, waiter, :blocks)
      link(blocker, waiter, :precedes)

      expect(described_class.counts_for([blocker.id, waiter.id])).to eq(
        blocker.id => { waiting_on: 0, blocking: 1 },
        waiter.id => { waiting_on: 1, blocking: 0 }
      )
    end

    it 'counts only open tickets at the other end, each by its own project' do
      waiter = ticket(project_x)
      link(ticket(project_y, 'Closed'), waiter)
      link(ticket(project_x, 'Closed'), waiter)
      link(ticket(project_without_status, 'Done'), waiter)
      held_up = [ticket(project_x), ticket(project_y, 'Closed')]
      held_up.each { |target| link(waiter, target) }
      link(waiter, ticket(project_x, 'Done'))

      expect(described_class.counts_for([waiter.id])).to eq(waiter.id => { waiting_on: 2, blocking: 2 })
    end

    it 'answers zero for a done ticket, a ticket without relations and an unknown id' do
      done = ticket(project_x, 'Done')
      link(ticket(project_x), done)
      lonely = ticket(project_x)
      unknown = SecureRandom.uuid

      expect(described_class.counts_for([done.id, lonely.id, unknown])).to eq(
        done.id => { waiting_on: 0, blocking: 0 },
        lonely.id => { waiting_on: 0, blocking: 0 },
        unknown => { waiting_on: 0, blocking: 0 }
      )
    end

    it 'refuses records instead of ids, rather than answering zero for all of them' do
      tickets = [ticket(project_x)]

      expect { described_class.counts_for(tickets) }.to raise_error(ArgumentError)
      expect { described_class.counts_for(Ticket.all) }.to raise_error(ArgumentError)
    end

    it 'asks nothing for no tickets' do
      expect(described_class.counts_for([])).to eq({})
    end

    describe 'query contract: one aggregation plus fixed preparation, whatever the size' do
      def query_count(&)
        queries = []
        callback = ->(*, payload) { queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
        queries.size
      end

      def tickets_with_relations(count, related:)
        tickets = Array.new(count) { |index| ticket([project_x, project_y, project_without_status][index % 3]) }
        tickets.each_cons(2) { |source, target| link(source, target) } if related
        tickets.map(&:id)
      end

      it 'uses the same number of queries for 3 and for 25 tickets, with and without relations' do
        id_sets = [tickets_with_relations(3, related: true), tickets_with_relations(25, related: true),
                   tickets_with_relations(3, related: false), tickets_with_relations(25, related: false)]

        # Four calls in a row are the measurement itself, not an N+1; this example counts
        # every query on its own, stricter than Prosopite's pattern match.
        counts = Prosopite.pause { id_sets.map { |ids| query_count { described_class.counts_for(ids) } } }

        expect(counts.uniq.size).to eq(1)
        expect(counts.first).to be <= 2
      end
    end
  end

  describe '.for' do
    it 'lists the open blockers of a ticket, across projects, by number' do
      waiter = ticket(project_x)
      later = ticket(project_y, 'Closed')
      earlier = ticket(project_x)
      link(later, waiter, :blocks)
      link(earlier, waiter, :precedes)
      link(ticket(project_x, 'Done'), waiter)
      link(ticket(project_x), waiter, :relates_to)
      link(waiter, ticket(project_x))

      expect(described_class.for(waiter).map(&:id)).to eq([earlier, later].sort_by(&:number).map(&:id))
    end

    it 'lists nothing for a ticket that is done itself' do
      done = ticket(project_x, 'Done')
      link(ticket(project_x), done)

      expect(described_class.for(done)).to be_empty
    end
  end

  # The relations section greys out what is done; it asks the same rule as the waiting state,
  # so a blocker never reads as open in the list and as done in the hint.
  describe '.open_ids' do
    it 'keeps the open tickets, each judged by its own project' do
      open_x = ticket(project_x)
      closed_x = ticket(project_x, 'Closed')
      closed_y = ticket(project_y, 'Closed')
      done_y = ticket(project_y, 'Done')

      expect(described_class.open_ids([open_x.id, closed_x.id, closed_y.id, done_y.id]))
        .to contain_exactly(open_x.id, closed_y.id)
    end

    it 'counts no status and a project without a done value as open' do
      without_status = ticket(project_x, nil)
      without_done = ticket(project_without_done, 'Closed')
      no_field = ticket(project_without_status, nil)

      expect(described_class.open_ids([without_status.id, without_done.id, no_field.id]))
        .to contain_exactly(without_status.id, without_done.id, no_field.id)
    end

    it 'asks nothing for no tickets and refuses records' do
      expect(described_class.open_ids([])).to eq([])
      expect { described_class.open_ids([ticket(project_x)]) }.to raise_error(ArgumentError)
    end
  end
end

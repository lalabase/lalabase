# frozen_string_literal: true

# == Schema Information
#
# Table name: tickets
#
#  id                       :uuid             not null, primary key
#  custom_attributes        :jsonb            not null
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  number                   :integer
#  summary                  :text
#  summary_generated_at     :datetime
#  ticket_type              :string           default("support"), not null
#  title                    :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  creator_id               :uuid             not null
#  organisation_id          :uuid             not null
#  parent_id                :uuid
#  project_id               :uuid             not null
#  updater_id               :uuid
#
# Indexes
#
#  index_tickets_on_creator_id                       (creator_id)
#  index_tickets_on_custom_attributes                (custom_attributes) USING gin
#  index_tickets_on_custom_attrs_not_null            (((custom_attributes IS NOT NULL))) WHERE (custom_attributes IS NOT NULL)
#  index_tickets_on_org_and_custom_attrs_exists      (organisation_id, ((custom_attributes IS NOT NULL)))
#  index_tickets_on_org_created                      (organisation_id,created_at)
#  index_tickets_on_organisation_id_and_ticket_type  (organisation_id,ticket_type)
#  index_tickets_on_parent_id                        (parent_id)
#  index_tickets_on_project_and_custom_attrs_exists  (project_id, ((custom_attributes IS NOT NULL)))
#  index_tickets_on_project_created                  (project_id,created_at)
#  index_tickets_on_project_creator                  (project_id,creator_id)
#  index_tickets_on_project_id_and_number            (project_id,number) UNIQUE
#  index_tickets_on_project_title                    (project_id,title)
#  index_tickets_on_project_updated                  (project_id,updated_at)
#  index_tickets_on_ticket_type                      (ticket_type)
#  index_tickets_title_fts                           (to_tsvector('german'::regconfig, (title)::text)) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => tickets.id) ON DELETE => nullify
#
require 'rails_helper'

RSpec.describe Ticket, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'validations' do
    subject { build(:ticket) }

    it { should validate_presence_of(:title) }
    it { should validate_uniqueness_of(:number).scoped_to(:project_id).allow_nil }

    it 'auto-assigns number on creation' do
      ticket = build(:ticket, number: nil)
      expect(ticket.number).to be_nil
      ticket.save!
      expect(ticket.number).to eq(1)
    end

    # The bound the MCP tool update_ticket checks first (terminal client S2). Without
    # it a long title reached PostgreSQL and failed on the btree index of
    # (project_id, title), as an internal error carrying the database's message.
    describe 'title length' do
      let(:limit) { Ticket::TITLE_MAX_LENGTH }

      it 'is 255 characters' do
        expect(limit).to eq(255)
      end

      it 'takes a new title of the limit and refuses one character more' do
        expect(build(:ticket, title: 'a' * (limit - 1))).to be_valid
        expect(build(:ticket, title: 'a' * limit)).to be_valid
        too_long = build(:ticket, title: 'a' * (limit + 1))
        expect(too_long).not_to be_valid
        expect(too_long.errors[:title]).to be_present
      end

      it 'refuses a change to a title one character over the limit' do
        ticket = create(:ticket, title: 'Kurz')
        expect(ticket.update(title: 'a' * limit)).to be(true)
        expect(ticket.update(title: 'a' * (limit + 1))).to be(false)
        expect(ticket.reload.title).to eq('a' * limit)
      end

      # Titles written before the bound existed stay: the bound applies to a title
      # that changes, so every other write on such a ticket still saves.
      it 'still saves another change on a ticket with an older, longer title' do
        ticket = create(:ticket, title: 'Kurz', custom_attributes: { 'status' => 'open' })
        ticket.update_column(:title, 'a' * 300)

        ticket.reload.custom_attributes = { 'status' => 'wip' }
        expect(ticket.save).to be(true)
        expect(ticket.reload.custom_attributes['status']).to eq('wip')
      end
    end
  end

  describe 'associations' do
    it { should belong_to(:creator).class_name('User').optional(true) }
    it { should belong_to(:updater).class_name('User').optional(true) }
    it { should belong_to(:organisation).required(false) } # acts_as_tenant handles this

    it { should have_many(:posts).dependent(:destroy) }
    it { should have_many(:ticket_assignments).dependent(:destroy) }
    it { should have_many(:assignees).through(:ticket_assignments) }
    it { should have_many(:fragments).dependent(:delete_all) }
    it { should have_many(:time_sessions).dependent(:nullify) }

    it 'creates a ticket with expected attributes' do
      ticket = create(:ticket, title: 'Bug Report', content: 'Something is broken')
      expect(ticket.title).to eq('Bug Report')
      expect(ticket.content.to_plain_text.strip).to eq('Something is broken')
      expect(ticket.project).to be_present
      expect(ticket.creator).to be_present
      expect(ticket.number).to be_present
    end
  end

  describe 'multi-tenant behavior' do
    it 'scopes tickets to the current organisation' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      ticket1 = nil
      ticket2 = nil

      ActsAsTenant.with_tenant(org1) do
        ticket1 = create(:ticket, title: 'Org1 Ticket')
        expect(Ticket.count).to eq(1)
        expect(Ticket.first.title).to eq('Org1 Ticket')
      end

      ActsAsTenant.with_tenant(org2) do
        ticket2 = create(:ticket, title: 'Org2 Ticket')
        expect(Ticket.count).to eq(1)
        expect(Ticket.first.title).to eq('Org2 Ticket')
      end

      # Verify both tickets exist in the database
      expect(Ticket.unscoped.count).to eq(2)
    end
  end

  # Who may be (stay) assigned: active members with ticket access, plus whoever
  # is assigned already. One rule for the edit form, REST, the board and MCP.
  describe '#assignable_user_ids' do
    let(:admin_role) { create(:admin_role, organisation: organisation) }
    let(:ticket) { create(:ticket, organisation: organisation) }
    let(:active) { create(:user).tap { |user| create(:membership, user: user, organisation: organisation, role: admin_role) } }
    let(:deactivated) do
      create(:user).tap { |user| create(:membership, user: user, organisation: organisation, role: admin_role, active: false) }
    end

    it 'takes an active member and leaves out a deactivated one' do
      expect(ticket.assignable_user_ids([active.id, deactivated.id])).to eq([active.id])
    end

    it 'keeps a deactivated member who is assigned already' do
      ticket.assignees << deactivated
      expect(ticket.assignable_user_ids([active.id, deactivated.id])).to contain_exactly(active.id, deactivated.id)
    end

    it 'keeps nobody on a ticket that is not saved yet' do
      fresh = build(:ticket, organisation: organisation, project: ticket.project)
      expect(fresh.assignable_user_ids([deactivated.id])).to be_empty
    end
  end

  describe 'assignee management' do
    it 'can be assigned to users' do
      ticket = create(:ticket)
      user1 = create(:user)
      user2 = create(:user)

      ticket.assignees << user1
      ticket.assignees << user2

      expect(ticket.assignees.count).to eq(2)
      expect(ticket.assignees.to_a).to include(user1, user2)
    end

    it 'can remove assignees' do
      ticket = create(:ticket)
      user = create(:user)

      ticket.assignees << user
      expect(ticket.assignees).to include(user)

      ticket.assignees.destroy(user)
      expect(ticket.assignees.reload).not_to include(user)
    end
  end

  describe 'search functionality' do
    it 'can be found via text search' do
      create(:ticket, title: 'Regular ticket')
      create(:ticket, title: 'Special ticket feature')

      results = Ticket.text_search('special')
      expect(results.count).to eq(1)
      expect(results.first.title).to eq('Special ticket feature')
    end

    it 'returns all tickets when search query is blank' do
      create(:ticket, title: 'First ticket')
      create(:ticket, title: 'Second ticket')

      results = Ticket.text_search('')
      expect(results.count).to eq(2)
    end
  end

  describe 'instance methods' do
    let(:ticket) { create(:ticket, title: 'Test Ticket', content: 'Test Content', organisation: organisation) }

    describe '#plain_text_version' do
      it 'combines title and content' do
        expect(ticket.plain_text_version).to eq("Test Ticket\nTest Content")
      end
    end

    describe '#create_embeddings?' do
      it 'always returns true (tickets always have embeddings)' do
        expect(ticket.create_embeddings?).to be true
      end
    end

    describe '#display_title' do
      it 'returns title with number prefix' do
        ticket = create(:ticket, title: 'Test Ticket')
        expect(ticket.display_title).to eq("##{ticket.number} Test Ticket")
      end
    end
  end

  describe 'ticket number assignment' do
    let(:project) { create(:project, organisation: organisation) }

    it 'assigns sequential numbers within a project' do
      ticket1 = create(:ticket,
                       project: project)

      ticket2 = create(:ticket,
                       project: project)

      expect(ticket1.number).to eq(1)
      expect(ticket2.number).to eq(2)
    end

    it 'starts numbering from 1 for each project' do
      project2 = create(:project, organisation: organisation)

      ticket1 = create(:ticket,
                       project: project)

      ticket2 = create(:ticket,
                       project: project2)

      expect(ticket1.number).to eq(1)
      expect(ticket2.number).to eq(1)
    end

    it 'does not reuse numbers when ticket is deleted' do
      ticket1 = create(:ticket,
                       project: project)

      create(:ticket,
             project: project)

      # Delete first ticket
      ticket1.destroy

      # Create new ticket - should get number 3, not 1
      ticket3 = create(:ticket,
                       project: project)

      expect(ticket3.number).to eq(3)
    end

    describe 'number reuse prevention' do
      it 'never reuses numbers even with multiple deletions and creations' do
        # Create initial tickets
        ticket1 = create(:ticket, project: project)
        ticket2 = create(:ticket, project: project)
        ticket3 = create(:ticket, project: project)

        expect(ticket1.number).to eq(1)
        expect(ticket2.number).to eq(2)
        expect(ticket3.number).to eq(3)

        # Delete middle ticket
        ticket2.destroy

        # Create new ticket - should get number 4, not 2
        ticket4 = create(:ticket, project: project)
        expect(ticket4.number).to eq(4)

        # Delete first and last tickets
        ticket1.destroy
        ticket3.destroy

        # Create more tickets - should continue sequence
        ticket5 = create(:ticket, project: project)
        ticket6 = create(:ticket, project: project)

        expect(ticket5.number).to eq(5)
        expect(ticket6.number).to eq(6)

        # Verify we still have tickets 4, 5, 6 in database
        remaining_tickets = Ticket.where(project: project).order(:number)
        expect(remaining_tickets.pluck(:number)).to eq([4, 5, 6])
      end

      it 'maintains separate number sequences per project even with deletions' do
        project2 = create(:project, organisation: organisation)

        # Create tickets in both projects
        p1_ticket1 = create(:ticket, project: project)
        p2_ticket1 = create(:ticket, project: project2)
        p1_ticket2 = create(:ticket, project: project)
        p2_ticket2 = create(:ticket, project: project2)

        # Verify initial numbering
        expect(p1_ticket1.number).to eq(1)
        expect(p2_ticket1.number).to eq(1)
        expect(p1_ticket2.number).to eq(2)
        expect(p2_ticket2.number).to eq(2)

        # Delete tickets from both projects
        p1_ticket1.destroy
        p2_ticket1.destroy

        # Create new tickets - should continue from 3 in each project
        p1_ticket3 = create(:ticket, project: project)
        p2_ticket3 = create(:ticket, project: project2)

        expect(p1_ticket3.number).to eq(3)
        expect(p2_ticket3.number).to eq(3)

        # Verify each project has its own sequence
        project1_numbers = Ticket.where(project: project).pluck(:number).sort
        project2_numbers = Ticket.where(project: project2).pluck(:number).sort

        expect(project1_numbers).to eq([2, 3])
        expect(project2_numbers).to eq([2, 3])
      end

      it 'preserves number gaps as audit trail of deleted tickets' do
        # Creating multiple tickets sequentially triggers repeated but independent
        # queries (validations, callbacks) — not real N+1s, so pause Prosopite.
        Prosopite.pause

        # Create 5 tickets
        tickets = (1..5).map do |i|
          create(:ticket,
                 title: "Ticket #{i}",
                 project: project)
        end

        # Verify sequential numbering
        expect(tickets.map(&:number)).to eq([1, 2, 3, 4, 5])

        # Delete tickets 2 and 4
        tickets[1].destroy  # number 2
        tickets[3].destroy  # number 4

        # Create new ticket
        new_ticket = create(:ticket, project: project)
        Prosopite.resume
        expect(new_ticket.number).to eq(6)

        # Verify remaining tickets and gaps
        remaining_numbers = Ticket.where(project: project).order(:number).pluck(:number)
        expect(remaining_numbers).to eq([1, 3, 5, 6])

        # The gaps (2, 4) serve as evidence that tickets were deleted
        all_created_numbers = [1, 2, 3, 4, 5, 6]
        expect(all_created_numbers - remaining_numbers).to eq([2, 4])
      end
    end

    describe 'concurrent number assignment' do
      it 'assigns unique numbers when multiple tickets are created in parallel' do
        # Use separate DB connections to simulate true concurrency.
        # Each thread opens its own connection and transaction, just like
        # two simultaneous web requests would.
        threads_count = 5
        barrier = Concurrent::CyclicBarrier.new(threads_count)
        results = Concurrent::Array.new

        threads = threads_count.times.map do
          Thread.new do
            # Each thread needs its own connection
            ActiveRecord::Base.connection_pool.with_connection do
              ActsAsTenant.with_tenant(organisation) do
                barrier.wait # synchronize all threads to start at the same time
                ticket = Ticket.create!(
                  title: "Concurrent ticket #{Thread.current.object_id}",
                  project: project,
                  creator: create(:user, organisation: organisation)
                )
                results << ticket.number
              end
            end
          end
        end

        threads.each(&:join)

        # All tickets should have unique, sequential numbers
        expect(results.sort).to eq((1..threads_count).to_a)
      end
    end

    describe '.find_by_number' do
      it 'finds ticket by number within project' do
        ticket = create(:ticket,
                        project: project)

        found_ticket = Ticket.find_by_number(project, ticket.number)
        expect(found_ticket).to eq(ticket)
      end

      it 'returns nil for non-existent number' do
        found_ticket = Ticket.find_by_number(project, 999)
        expect(found_ticket).to be_nil
      end
    end

    describe 'ordering scopes' do
      it 'orders by number ascending' do
        ticket1 = create(:ticket,
                         project: project)

        ticket2 = create(:ticket,
                         project: project)

        tickets = Ticket.ordered_by_number
        expect(tickets.first).to eq(ticket1)
        expect(tickets.last).to eq(ticket2)
      end

      it 'orders by number descending' do
        ticket1 = create(:ticket,
                         project: project)

        ticket2 = create(:ticket,
                         project: project)

        tickets = Ticket.ordered_by_number_desc
        expect(tickets.first).to eq(ticket2)
        expect(tickets.last).to eq(ticket1)
      end
    end
  end

  describe 'dependency behavior' do
    it 'destroys dependent records when ticket is destroyed' do
      ticket = create(:ticket)
      create(:post, ticket: ticket)
      user = create(:user)
      create(:ticket_assignment, ticket: ticket, user: user)
      time_session = create(:time_session, ticket: ticket)

      # Create a fragment for the ticket
      create(:fragment, :for_ticket, fragmentable: ticket, organisation: organisation)

      expect do
        ticket.destroy
      end.to change(Ticket, :count).by(-1)
                                   .and change(Post, :count).by(-1)
                                                            .and change(TicketAssignment, :count).by(-1)
                                                                                                 .and change(Fragment, :count).by(-1)

      # Time sessions should be nullified, not destroyed
      expect(TimeSession.exists?(time_session.id)).to be true
      expect(TimeSession.find(time_session.id).ticket_id).to be_nil
    end
  end

  describe 'configured-order custom attribute sorting' do
    let(:project) { create(:project, organisation: organisation) }
    let(:user) { create(:user, organisation: organisation) }
    # Configured option order (low → normal → high → urgent): position is the sort key.
    let(:ordered) { %w[low normal high urgent] }

    def ticket_with(priority)
      attrs = priority.nil? ? {} : { 'priority' => priority }
      create(:ticket, project: project, organisation: organisation, creator: user, custom_attributes: attrs)
    end

    describe '.sortable_custom_attribute' do
      it 'maps the bare attribute key to itself' do
        expect(Ticket.sortable_custom_attribute('priority')).to eq('priority')
        expect(Ticket.sortable_custom_attribute('status')).to eq('status')
      end

      it 'strips the custom_ column prefix used by the view header links' do
        expect(Ticket.sortable_custom_attribute('custom_priority')).to eq('priority')
        expect(Ticket.sortable_custom_attribute('custom_status')).to eq('status')
      end

      it 'returns nil for non-sortable columns' do
        expect(Ticket.sortable_custom_attribute('created_at')).to be_nil
        expect(Ticket.sortable_custom_attribute('custom_anything_else')).to be_nil
        expect(Ticket.sortable_custom_attribute(nil)).to be_nil
      end
    end

    describe '.custom_attribute_order_sql' do
      it 'quotes dynamic values (injection-safe)' do
        sql = Ticket.custom_attribute_order_sql('priority', ["x'; DROP TABLE tickets; --"], 'asc')
        # The single quote is doubled by the connection quoting; the payload is never raw.
        expect(sql).to include("''")
        expect(sql).not_to match(/WHEN 'x'; DROP TABLE/)
      end

      it 'falls back to an alphabetical, blanks-last order when no configured values exist' do
        sql = Ticket.custom_attribute_order_sql('priority', [], 'asc')
        expect(sql).to include('NULLS LAST')
        expect(sql).not_to include('CASE')
      end
    end

    describe '.ordered_by_custom_attribute' do
      it 'orders ascending by the configured option order' do
        t_high = ticket_with('high')
        t_low = ticket_with('low')
        t_urgent = ticket_with('urgent')

        result = project.tickets.ordered_by_custom_attribute('priority', ordered, 'asc').to_a

        expect(result).to eq([t_low, t_high, t_urgent])
      end

      it 'reverses the known values on desc' do
        t_high = ticket_with('high')
        t_low = ticket_with('low')

        result = project.tickets.ordered_by_custom_attribute('priority', ordered, 'desc').to_a

        expect(result).to eq([t_high, t_low])
      end

      it 'matches values case-insensitively' do
        t_upper = ticket_with('HIGH')
        t_low = ticket_with('low')

        result = project.tickets.ordered_by_custom_attribute('priority', ordered, 'asc').to_a

        # 'HIGH' resolves to the configured 'high' position, after 'low'.
        expect(result).to eq([t_low, t_upper])
      end

      it 'sorts unknown and blank values last in both directions' do
        t_known = ticket_with('high')
        t_unknown = ticket_with('does_not_exist')
        t_blank = ticket_with(nil)

        asc = project.tickets.ordered_by_custom_attribute('priority', ordered, 'asc').to_a
        desc = project.tickets.ordered_by_custom_attribute('priority', ordered, 'desc').to_a

        expect(asc.first).to eq(t_known)
        expect(asc.last(2)).to contain_exactly(t_unknown, t_blank)
        expect(desc.first).to eq(t_known)
        expect(desc.last(2)).to contain_exactly(t_unknown, t_blank)
      end
    end
  end

  describe 'due date (Fälligkeit)' do
    let(:project) { create(:project, organisation: organisation) }

    before do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                             { 'value' => 'closed', 'labels' => { 'de' => 'Zu', 'en' => 'Closed' },
                                               'system_functions' => [SystemFunctions::Registry::IS_CLOSED] }
                                           ] })
      create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date',
                                           labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' })
    end

    # build (no save) where we need to bypass write-time date validation (legacy garbage);
    # create (persisted) only with valid ISO/blank values for scope + sort tests.
    def built(due:, status: 'open')
      build(:ticket, project: project, organisation: organisation,
                     custom_attributes: { 'due_date' => due, 'status' => status })
    end

    def persisted(due:, status: 'open')
      create(:ticket, project: project, organisation: organisation,
                      custom_attributes: { 'due_date' => due, 'status' => status })
    end

    describe '#due_on' do
      it 'parses a stored ISO date' do
        expect(built(due: '2026-06-30').due_on).to eq(Date.new(2026, 6, 30))
      end

      it 'is nil when blank' do
        expect(built(due: '').due_on).to be_nil
      end

      it 'is nil for legacy garbage without raising' do
        expect(built(due: 'not-a-date').due_on).to be_nil
      end
    end

    describe '#overdue?' do
      it 'is true when due before today and not closed' do
        expect(built(due: 1.day.ago.to_date.iso8601).overdue?).to be(true)
      end

      it 'is false when due today (boundary n)' do
        expect(built(due: Date.current.iso8601).overdue?).to be(false)
      end

      it 'is false when due in the future' do
        expect(built(due: 1.day.from_now.to_date.iso8601).overdue?).to be(false)
      end

      it 'is false without a due date' do
        expect(built(due: '').overdue?).to be(false)
      end

      it 'is false when overdue but the status is closed' do
        expect(built(due: 1.day.ago.to_date.iso8601, status: 'closed').overdue?).to be(false)
      end
    end

    describe '.overdue scope' do
      it 'includes only overdue, non-closed tickets (boundary + closed + blank excluded)' do
        overdue_open   = persisted(due: 2.days.ago.to_date.iso8601)
        persisted(due: Date.current.iso8601)                                   # due today → not overdue
        persisted(due: 3.days.from_now.to_date.iso8601)                        # future
        persisted(due: 2.days.ago.to_date.iso8601, status: 'closed') # overdue but closed
        persisted(due: '') # no due date

        expect(project.tickets.overdue).to contain_exactly(overdue_open)
      end

      it 'keeps untriaged (nil status) overdue tickets' do
        untriaged = create(:ticket, project: project, organisation: organisation,
                                    custom_attributes: { 'due_date' => 2.days.ago.to_date.iso8601 })

        expect(project.tickets.overdue).to include(untriaged)
      end
    end

    describe '.due_in_past scope' do
      # The raw date predicate. Relative-date boundary (n-1/n/n+1 around Date.current), same approach
      # as the .overdue / .due_within specs above (TimeHelpers is not included in this model spec).
      it 'matches strictly before today and excludes today, future and blank (boundary n-1/n/n+1)' do
        yesterday = persisted(due: (Date.current - 1).iso8601)
        persisted(due: Date.current.iso8601)        # today (boundary n) -> out
        persisted(due: (Date.current + 1).iso8601)  # tomorrow -> out
        persisted(due: '')                          # blank -> out

        expect(project.tickets.due_in_past).to contain_exactly(yesterday)
      end

      # The defining difference from .overdue: due_in_past has NO status exclusion. If someone
      # "simplifies" due_in_past to call excluding_status_values, this turns red.
      it 'includes a CLOSED past-due ticket (no status exclusion, unlike .overdue)' do
        closed_overdue = persisted(due: (Date.current - 2).iso8601, status: 'closed')

        expect(project.tickets.due_in_past).to include(closed_overdue)
        expect(project.tickets.overdue).not_to include(closed_overdue)
      end
    end

    describe 'sorting by due_date' do
      it 'orders ascending chronologically with blanks last' do
        t_late  = persisted(due: '2026-12-31')
        t_early = persisted(due: '2026-01-01')
        t_blank = persisted(due: '')

        sql = Ticket.custom_attribute_sort_sql('due_date', project, 'asc')
        result = project.tickets.reorder(Arel.sql(sql)).to_a

        expect(result.first(2)).to eq([t_early, t_late])
        expect(result.last).to eq(t_blank)
      end

      it 'orders descending with blanks still last' do
        t_late  = persisted(due: '2026-12-31')
        t_early = persisted(due: '2026-01-01')
        t_blank = persisted(due: '')

        sql = Ticket.custom_attribute_sort_sql('due_date', project, 'desc')
        result = project.tickets.reorder(Arel.sql(sql)).to_a

        expect(result.first(2)).to eq([t_late, t_early])
        expect(result.last).to eq(t_blank)
      end
    end

    describe '.due_within' do
      # BETWEEN is inclusive on BOTH ends. The boundary cases below kill the off-by-one mutations
      # (BETWEEN -> `>`/`<`, or shifting a bound by a day): a ticket due exactly on `from` or `to`
      # must be IN, and the day on either side must be OUT.
      it 'includes tickets due on both range boundaries and excludes the days just outside' do
        before_from = persisted(due: (Date.current - 1).iso8601)
        on_from     = persisted(due: Date.current.iso8601)
        on_to       = persisted(due: (Date.current + 3).iso8601)
        after_to    = persisted(due: (Date.current + 4).iso8601)

        result = project.tickets.due_within(Date.current, Date.current + 3)

        expect(result).to include(on_from, on_to)
        expect(result).not_to include(before_from, after_to)
      end
    end

    describe '.due_date_preset_range' do
      it 'returns nil for overdue (the overdue scope handles it — it is not a plain forward range)' do
        expect(Ticket.due_date_preset_range('overdue')).to be_nil
      end

      it 'returns nil for an unknown preset' do
        expect(Ticket.due_date_preset_range('bogus')).to be_nil
      end

      it 'maps each forward range preset to its exact [from, to]' do
        # Pins the boundary arithmetic: end_of_week and +7 are the off-by-one-prone edges.
        expect(Ticket.due_date_preset_range('due_today')).to eq([Date.current, Date.current])
        expect(Ticket.due_date_preset_range('due_this_week')).to eq([Date.current, Date.current.end_of_week])
        expect(Ticket.due_date_preset_range('due_next_7_days')).to eq([Date.current, Date.current + 7])
      end
    end

    describe '.matching_due_preset' do
      it "'overdue' delegates to the overdue scope (past + not closed only)" do
        overdue_open = persisted(due: (Date.current - 2).iso8601)
        persisted(due: (Date.current - 2).iso8601, status: 'closed') # overdue but closed → excluded

        expect(project.tickets.matching_due_preset('overdue')).to contain_exactly(overdue_open)
      end

      it "'due_today' matches only today (boundary: not yesterday, not tomorrow)" do
        today = persisted(due: Date.current.iso8601)
        persisted(due: (Date.current - 1).iso8601)
        persisted(due: (Date.current + 1).iso8601)

        expect(project.tickets.matching_due_preset('due_today')).to contain_exactly(today)
      end

      it "'due_this_week' spans today..end_of_week and excludes the day after (boundary)" do
        today = persisted(due: Date.current.iso8601)
        eow   = persisted(due: Date.current.end_of_week.iso8601)
        after = persisted(due: (Date.current.end_of_week + 1).iso8601)

        result = project.tickets.matching_due_preset('due_this_week')
        expect(result).to include(today, eow)
        expect(result).not_to include(after)
      end

      it "'due_next_7_days' includes today+7 (boundary n) and excludes today+8 (n+1)" do
        boundary = persisted(due: (Date.current + 7).iso8601)
        beyond   = persisted(due: (Date.current + 8).iso8601)

        result = project.tickets.matching_due_preset('due_next_7_days')
        expect(result).to include(boundary)
        expect(result).not_to include(beyond)
      end

      # Whitelist positive-iteration: every canonical preset must BUILD a usable scope. This catches a
      # preset added to DUE_DATE_PRESET_KEYS but forgotten in due_date_preset_range — that gap makes
      # due_within(*nil) raise at scope-build time, so this loop turns red the moment the two lists
      # drift apart. We don't enumerate (no .to_a): the drift crashes while building the relation, and
      # not executing keeps the loop of identical range queries from tripping the N+1 detector.
      it 'resolves every canonical preset key without raising' do
        Ticket::DUE_DATE_PRESET_KEYS.each do |preset|
          expect { project.tickets.matching_due_preset(preset) }.not_to raise_error, "preset #{preset.inspect} crashed"
        end
      end
    end

    describe '.order_by_due_date' do
      it 'orders ascending by date with blanks last by DEFAULT (no direction arg)' do
        late  = persisted(due: '2026-12-31')
        early = persisted(due: '2026-01-01')
        blank = persisted(due: '')

        result = project.tickets.order_by_due_date.to_a

        expect(result.first(2)).to eq([early, late])
        expect(result.last).to eq(blank)
      end

      it 'orders descending when asked, blanks still last' do
        late  = persisted(due: '2026-12-31')
        early = persisted(due: '2026-01-01')
        blank = persisted(due: '')

        result = project.tickets.order_by_due_date('desc').to_a

        expect(result.first(2)).to eq([late, early])
        expect(result.last).to eq(blank)
      end
    end
  end

  describe '.high_priority scope' do
    let(:project) { create(:project, organisation: organisation) }

    # Priority is a raw JSONB attribute (no TicketAttributeDefinition needed for the SQL scope).
    def ticket_with_priority(priority)
      attrs = priority.nil? ? {} : { 'priority' => priority }
      create(:ticket, project: project, organisation: organisation, custom_attributes: attrs)
    end

    # Iterate over the CONSTANT, not hardcoded strings: shrinking HIGH_PRIORITY_VALUES (e.g. dropping
    # 'dringend') must turn a test red, not pass silently.
    Ticket::HIGH_PRIORITY_VALUES.each do |value|
      it "includes a ticket with priority #{value.inspect}" do
        match = ticket_with_priority(value)
        expect(project.tickets.high_priority).to include(match)
      end

      it "matches #{value.inspect} case-insensitively (#{value.upcase})" do
        match = ticket_with_priority(value.upcase)
        expect(project.tickets.high_priority).to include(match)
      end
    end

    # Negative side: non-high values must NOT match (catches widening the IN list).
    %w[normal medium mittel low niedrig gering].each do |value|
      it "excludes non-high priority #{value.inspect}" do
        other = ticket_with_priority(value)
        expect(project.tickets.high_priority).not_to include(other)
      end
    end

    it 'excludes tickets without any priority set' do
      none = ticket_with_priority(nil)
      expect(project.tickets.high_priority).not_to include(none)
    end
  end

  describe '.assigned_to' do
    it "returns only tickets assigned to the given user, not other users' tickets" do
      organisation = create(:organisation)
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        user = create(:user)
        other = create(:user)
        mine = create(:ticket, project: project, organisation: organisation)
        theirs = create(:ticket, project: project, organisation: organisation)
        create(:ticket_assignment, ticket: mine, user: user)
        create(:ticket_assignment, ticket: theirs, user: other)

        expect(Ticket.assigned_to(user)).to contain_exactly(mine)
      end
    end
  end

  # The shared formatter behind the assistant's reference: the system prompt writes
  # the title into a sentence, the reference chip into a 380px pill. Two callers,
  # two caps, ONE form -- they had the same three-call chain written out twice.
  describe '#one_line_title' do
    let(:organisation) { create(:organisation) }

    def ticket_titled(title)
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: create(:project, organisation: organisation),
                        organisation: organisation, title: title)
      end
    end

    it 'keeps a short title whole, number and all' do
      ticket = ticket_titled('Anmeldung schlaegt fehl')

      expect(ticket.one_line_title(max: 80)).to eq("##{ticket.number} Anmeldung schlaegt fehl")
    end

    it 'collapses newlines and runs of spaces to one line' do
      ticket = ticket_titled("Absturz\n\n  beim   Speichern")

      expect(ticket.one_line_title(max: 80)).to eq("##{ticket.number} Absturz beim Speichern")
    end

    # The cap is the caller's number, and it has to bite AT it. Boundary spelled
    # out rather than "a long title gets shorter": n-1 whole, n whole, n+1 cut.
    it 'cuts at the cap and not one character later' do
      ticket = ticket_titled('x' * 200)
      full = "##{ticket.number} #{'x' * 200}"
      cap = full.length

      expect(ticket.one_line_title(max: cap - 1).length).to eq(cap - 1)
      expect(ticket.one_line_title(max: cap)).to eq(full)
      expect(ticket.one_line_title(max: cap + 1)).to eq(full)
    end

    # The reason the collapse comes FIRST: a pasted stacktrace must not spend its
    # whole budget on newlines and hand back a nearly empty line.
    it 'spends the budget on words, not on the whitespace it just collapsed' do
      ticket = ticket_titled("Absturz#{"\n" * 60}beim Speichern")

      expect(ticket.one_line_title(max: 30)).to include('Absturz beim')
    end
  end
end

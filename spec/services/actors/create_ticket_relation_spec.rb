# frozen_string_literal: true

require 'rails_helper'

# Linking two tickets (doc/ticket_relations_plan.md, revision 4, §6). The seven labels flip
# onto four stored types, a waiting edge that would close a cycle is refused, and every
# refusal comes back as a failure Result, never as an exception. No history, no notification.
RSpec.describe Actors::CreateTicketRelation do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { create(:ticket, project: project, title: 'Secret login bug') }
  let(:other_ticket) { create(:ticket, project: other_project, title: 'Hidden migration') }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def link(kind, from: ticket, to: other_ticket, delay_days: nil)
    described_class.call(ticket: from, other_ticket: to, kind: kind, delay_days: delay_days, current_user: user)
  end

  # Another race: the other ticket is deleted after this request validated, before its INSERT.
  def delete_the_other_ticket_after_validation
    allow(TicketRelation).to receive(:new).and_wrap_original do |original, **attributes|
      original.call(**attributes).tap do |relation|
        allow(relation).to receive(:valid?).and_wrap_original do |valid, *args|
          valid.call(*args).tap do
            Ticket.connection.execute(Ticket.sanitize_sql_array(['DELETE FROM tickets WHERE id = ?', other_ticket.id]))
          end
        end
      end
    end
  end

  # The race window: another request inserts the same relates_to row after this one validated.
  def insert_the_same_row_after_validation
    allow(TicketRelation).to receive(:new).and_wrap_original do |original, **attributes|
      original.call(**attributes).tap do |relation|
        allow(relation).to receive(:valid?).and_wrap_original do |valid, *args|
          valid.call(*args).tap do
            values = [organisation.id, ticket.id, other_ticket.id, TicketRelation.relation_types.fetch('relates_to')]
            TicketRelation.connection.execute(TicketRelation.sanitize_sql_array([<<~SQL.squish, *values]))
              INSERT INTO ticket_relations (organisation_id, source_ticket_id, target_ticket_id, relation_type, created_at, updated_at)
              VALUES (?, ?, ?, ?, NOW(), NOW())
            SQL
          end
        end
      end
    end
  end

  describe 'the seven labels' do
    {
      'blocks' => [:ticket, :other_ticket, 'blocks'],
      'blocked_by' => [:other_ticket, :ticket, 'blocks'],
      'relates_to' => [:ticket, :other_ticket, 'relates_to'],
      'duplicates' => [:ticket, :other_ticket, 'duplicates'],
      'duplicated_by' => [:other_ticket, :ticket, 'duplicates'],
      'precedes' => [:ticket, :other_ticket, 'precedes'],
      'follows' => [:other_ticket, :ticket, 'precedes']
    }.each do |kind, (source, target, type)|
      it "stores #{kind} as #{source} #{type} #{target}" do
        result = link(kind)

        expect(result).to be_success
        expect(result.resource).to be_a(TicketRelation).and(be_persisted)
        expect(TicketRelation.pluck(:source_ticket_id, :target_ticket_id, :relation_type))
          .to eq([[send(source).id, send(target).id, type]])
      end
    end

    it 'covers every label of TicketRelation::KINDS' do
      expect(TicketRelation::KINDS.keys).to contain_exactly(
        'blocks', 'blocked_by', 'relates_to', 'duplicates', 'duplicated_by', 'precedes', 'follows'
      )
    end

    it 'keeps the delay of precedes and follows' do
      link('follows', delay_days: 3)

      expect(TicketRelation.sole).to have_attributes(source_ticket_id: other_ticket.id, delay_days: 3)
    end

    it 'refuses an unknown label as a failure' do
      result = link('depends_on')

      expect(result).not_to be_success
      expect(result.code).to eq(:unknown_kind)
      expect(result.errors).to eq([I18n.t('services.actors.create_ticket_relation.unknown_kind')])
      expect(TicketRelation.count).to eq(0)
    end
  end

  describe 'cycles' do
    it 'refuses the reverse of a blocks edge, without naming a ticket' do
      link('blocks')

      result = link('blocks', from: other_ticket, to: ticket)

      expect(result).not_to be_success
      expect(result.code).to eq(:cycle)
      expect(result.errors).to eq([I18n.t('services.actors.create_ticket_relation.would_create_cycle')])
      expect(result.errors.join).not_to include(ticket.title, other_ticket.title)
      expect(TicketRelation.count).to eq(1)
    end

    it 'refuses a cycle mixed from blocks and precedes, also through a flipped label' do
      link('blocks')

      # On other_ticket's page: "other_ticket is followed by ticket" is stored as other_ticket precedes ticket.
      expect(link('precedes', from: other_ticket, to: ticket).code).to eq(:cycle)
      # On ticket's page: "ticket follows other_ticket" is the same row.
      expect(link('follows', from: ticket, to: other_ticket).code).to eq(:cycle)
    end

    it 'leaves nothing on the ticket objects that a later save of them could write' do
      link('blocks')
      expect(link('blocks', from: other_ticket, to: ticket).code).to eq(:cycle)

      expect do
        ticket.save!
        other_ticket.save!
      end.not_to change(TicketRelation, :count)
    end

    it 'refuses a three-cycle across three projects' do
      third = create(:ticket, project: ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) })
      link('blocks', from: ticket, to: other_ticket)
      link('precedes', from: other_ticket, to: third)

      expect(link('blocks', from: third, to: ticket).code).to eq(:cycle)
    end

    # A check the wrong way round (does the new source reach the new target?) refuses exactly
    # this edge, which closes no cycle.
    it 'allows a shortcut along an existing chain (A -> B -> C, then A -> C)' do
      third = create(:ticket, project: project)
      link('blocks', from: ticket, to: other_ticket)
      link('precedes', from: other_ticket, to: third)

      expect(link('blocks', from: ticket, to: third)).to be_success
    end

    it 'lets relates_to and duplicates run both ways around a blocking pair' do
      link('blocks')

      expect(link('relates_to', from: other_ticket, to: ticket)).to be_success
      expect(link('duplicated_by', from: ticket, to: other_ticket)).to be_success
    end
  end

  describe 'failures from the model' do
    it 'maps a validation error to a failure Result' do
      result = link('blocks', to: ticket)

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(result.errors).to include(I18n.t('activerecord.errors.models.ticket_relation.self_reference'))
    end

    it 'maps a delay on a non-waiting label to a failure Result' do
      expect(link('relates_to', delay_days: 2).code).to eq(:validation_failed)
    end

    it 'answers "already linked" when the unique index catches what the validation could not see yet' do
      insert_the_same_row_after_validation

      result = link('relates_to')

      expect(result).not_to be_success
      expect(result.code).to eq(:already_linked)
      expect(result.errors).to eq([I18n.t('services.actors.create_ticket_relation.already_linked')])
    end

    # Review round 3 (30.09.2026): the foreign key refused the row, and the raw PostgreSQL text
    # came back as an internal error.
    it 'answers that a ticket is gone when it disappears between the check and the write' do
      delete_the_other_ticket_after_validation

      result = link('relates_to')

      expect(result).not_to be_success
      expect(result.code).to eq(:ticket_missing)
      expect(result.errors).to eq([I18n.t('services.actors.create_ticket_relation.ticket_missing')])
    end

    # Review step 2 (30.09.2026): inside a caller's transaction the refused INSERT aborted that
    # transaction, and the caller's next query failed. The save runs in a savepoint now.
    it 'leaves a surrounding transaction usable after the unique index refused the row' do
      insert_the_same_row_after_validation

      ActiveRecord::Base.transaction do
        expect(link('relates_to').code).to eq(:already_linked)
        expect(TicketRelation.count).to eq(0)
      end
    end
  end

  describe 'side effects' do
    # The test adapter, so perform_enqueued_jobs can run whatever the write enqueued.
    around do |example|
      previous = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
    ensure
      ActiveJob::Base.queue_adapter = previous
    end

    # Outside perform_enqueued_jobs: inside it the test adapter runs a job at once and files it
    # under performed_jobs, so have_enqueued_job would pass whatever happens.
    it 'enqueues no job' do
      ticket
      other_ticket

      expect { link('blocks') }.not_to have_enqueued_job
    end

    it 'writes no activity, no outbox event and, after running whatever it enqueued, no notification' do
      third = create(:ticket, project: project)
      ticket
      other_ticket

      expect do
        perform_enqueued_jobs do
          link('blocks')
          link('relates_to', from: other_ticket, to: third)
        end
      end.not_to(change { [Activity.count, OutboxEvent.count, Notification.count] })
      expect(TicketRelation.count).to eq(2)
    end

    it 'does not touch either ticket' do
      stamps = -> { Ticket.where(id: [ticket.id, other_ticket.id]).order(:id).pluck(:updated_at) }
      before = stamps.call

      link('blocks')

      expect(stamps.call).to eq(before)
    end
  end
end

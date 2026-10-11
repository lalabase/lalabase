# frozen_string_literal: true

require 'rails_helper'

# Unlinking two tickets (doc/ticket_relations_plan.md, revision 4, §6). The relation is found
# from either end of the ticket shown, exactly one row goes, and a relation that does not touch
# that ticket is not found. No history, no notification.
RSpec.describe Actors::DestroyTicketRelation do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  # Before the let! below: those run as hooks in the order they are declared.
  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:ticket_a) { create(:ticket, project: project) }
  let(:ticket_b) { create(:ticket, project: project) }
  let(:ticket_c) { create(:ticket, project: project) }
  let!(:relation) { TicketRelation.create!(source_ticket: ticket_a, target_ticket: ticket_b, relation_type: :blocks) }
  let!(:neighbour) { TicketRelation.create!(source_ticket: ticket_a, target_ticket: ticket_c, relation_type: :relates_to) }

  def unlink(ticket, relation_id)
    described_class.call(ticket: ticket, relation_id: relation_id, current_user: user)
  end

  it 'removes the relation from its source ticket, and only that row' do
    result = unlink(ticket_a, relation.id)

    expect(result).to be_success
    expect(result.resource).to be_nil
    expect(TicketRelation.pluck(:id)).to eq([neighbour.id])
  end

  it 'removes the relation from its target ticket' do
    expect(unlink(ticket_b, relation.id)).to be_success
    expect(TicketRelation.pluck(:id)).to eq([neighbour.id])
  end

  it 'does not find a relation that does not touch the ticket' do
    result = unlink(ticket_c, relation.id)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(result.errors).to eq([I18n.t('services.actors.destroy_ticket_relation.not_found')])
    expect(TicketRelation.count).to eq(2)
  end

  it 'does not find an unknown id' do
    expect(unlink(ticket_a, SecureRandom.uuid).code).to eq(:not_found)
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
      expect { unlink(ticket_a, relation.id) }.not_to have_enqueued_job
    end

    it 'writes no activity, no outbox event and, after running whatever it enqueued, no notification' do
      expect do
        perform_enqueued_jobs { unlink(ticket_a, relation.id) }
      end.not_to(change { [Activity.count, OutboxEvent.count, Notification.count] })
      expect(TicketRelation.pluck(:id)).to eq([neighbour.id])
    end
  end
end

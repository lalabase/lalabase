# frozen_string_literal: true

require 'rails_helper'

# What: Trackable#activity_context (doc/ticket_bulk_edit_plan.md, D4).
# Type: model spec on Ticket.
# Why: the one generic hook of the bulk edit. The context lands in the
#   parameters of every activity the save creates, and a save without a
#   context is exactly today's save.
RSpec.describe 'Trackable#activity_context', :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    bulk_project_setup
    Current.user = writer
  end
  after do
    ActsAsTenant.current_tenant = nil
    Current.user = nil
  end

  it 'merges the context into every activity of the save' do
    ticket = bulk_ticket
    ticket.activity_context = { 'bulk_run_id' => 'run-1', 'skip_notifications' => true }

    ticket.update!(custom_attributes: { 'status' => 'wip' })

    activity = Activity.find_by(trackable: ticket, action: 'status_changed')
    expect(activity.parameters).to include('bulk_run_id' => 'run-1', 'skip_notifications' => true)
    expect(OutboxEvent.where(activity_id: activity.id)).not_to exist
  end

  it 'changes nothing without a context' do
    ticket = bulk_ticket

    ticket.update!(custom_attributes: { 'status' => 'wip' })

    activity = Activity.find_by(trackable: ticket, action: 'status_changed')
    expect(activity.parameters.keys).not_to include('bulk_run_id', 'skip_notifications')
    expect(OutboxEvent.where(activity_id: activity.id)).to exist
  end
end

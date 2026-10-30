# frozen_string_literal: true

require 'rails_helper'

# What: which refusal of update_ticket wins when a call has several faults.
# Type: service spec, through #execute.
# Why: the checks moved into Tickets::Change (REST R3b), and the tool's ticket_id
#   stands between two of them: keys and encoding first, then the id, then the
#   kind and the values. Each text is pinned elsewhere; only the order is pinned
#   here. Green on the code before the extraction, so an MCP answer stays the
#   one it was.
RSpec.describe Lalabase::Tools::UpdateTicket do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) do
    Lalabase::Tools::Context.new(actor: writer, organisation: organisation, project: project, authorization: recorder)
  end
  let(:ticket) { bulk_ticket({ 'status' => 'open' }, title: 'Login bricht ab') }

  before { bulk_project_setup }
  after { ActsAsTenant.current_tenant = nil }

  def broken = "x\xFF".dup.force_encoding('UTF-8')

  def error_of(args)
    described_class.execute(args: args, context: context).error
  end

  it 'answers an unknown argument before a broken ticket_id' do
    expect(error_of(ticket_id: 'oops', status: 'wip', priority: 'low')).to eq('unknown arguments: priority')
  end

  it 'answers an unknown argument before bytes that are no UTF-8' do
    expect(error_of(ticket_id: ticket.id, title: broken, priority: 'low')).to eq('unknown arguments: priority')
  end

  it 'answers a ticket_id of invalid bytes as bytes, not as a format' do
    expect(error_of(ticket_id: broken, status: 'wip')).to eq('arguments must be valid UTF-8')
  end

  it 'answers invalid bytes before a missing ticket_id' do
    expect(error_of(status: broken)).to eq('arguments must be valid UTF-8')
  end

  it 'answers a missing ticket_id before a mixed call' do
    expect(error_of(title: 'Neu', status: 'wip')).to eq('ticket_id is required')
  end

  it 'answers a malformed ticket_id before a value it cannot read' do
    expect(error_of(ticket_id: 'oops', status: 5)).to eq('invalid ticket_id format')
  end

  it 'answers a mixed call before a value it cannot read' do
    expect(error_of(ticket_id: ticket.id, title: 5, status: 'wip')).to match(/\Aexactly one change per call/)
  end

  it 'answers the add list before the remove list' do
    expect(error_of(ticket_id: ticket.id, add_assignee_ids: 'x', remove_assignee_ids: 'y'))
      .to eq('add_assignee_ids must be a list of user UUIDs or "me"')
  end

  it 'answers a value it cannot read before the ticket lookup' do
    expect(error_of(ticket_id: SecureRandom.uuid, status: 5)).to eq('status must be a string')
  end

  it 'answers a list over the limit before an invalid id in it' do
    expect(error_of(ticket_id: ticket.id, add_assignee_ids: ['oops'] * 51)).to eq('at most 50 user ids per list')
  end

  it 'answers an invalid id in the remove list before the overlap' do
    expect(error_of(ticket_id: ticket.id, add_assignee_ids: ['me'], remove_assignee_ids: %w[me oops]))
      .to eq('invalid user id in remove_assignee_ids')
  end
end

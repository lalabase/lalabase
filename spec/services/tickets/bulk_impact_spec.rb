# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::BulkImpact, the numbers the move and delete dialogs name
#   (doc/ticket_bulk_edit_plan.md, D15, slice 7).
# Type: service spec.
# Why: the confirmation names what goes with the tickets and what stays behind,
#   counted from the live selection: comments and attachments go, time sessions
#   lose the ticket, sub-tickets outside the selection become standalone, a
#   hierarchy keeps a ticket from moving, and a target project loses the
#   assignments and subscriptions of people without access there.
RSpec.describe Tickets::BulkImpact, :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:target) { create(:project, organisation: organisation) }

  before { bulk_project_setup }
  after { ActsAsTenant.current_tenant = nil }

  it 'counts what a delete takes with it and what stays behind' do
    parent = bulk_ticket(title: 'Parent')
    child = create(:ticket, project: project, organisation: organisation, creator: writer, parent: parent, title: 'Child')
    other = bulk_ticket(title: 'Other')
    2.times { create(:post, ticket: parent, user: writer, organisation: organisation) }
    create(:ticket_document, ticket: other, organisation: organisation)
    create(:time_session, project: project, organisation: organisation, creator: writer, ticket: other)

    impact = described_class.call(project: project, ticket_ids: [parent.id, other.id])
    expect(impact).to eq(count: 2, posts: 2, documents: 1, time_sessions: 1, children: 1, hierarchy: 1)

    with_child = described_class.call(project: project, ticket_ids: [parent.id, child.id])
    expect(with_child).to include(count: 2, children: 0, hierarchy: 2)
  end

  it 'counts the assignments and subscriptions a target project cannot keep' do
    create(:membership, user: outsider, organisation: organisation, role: create(:role, organisation: organisation, title: 'Standard'))
    create(:project_permission, user: outsider, project: project, tickets_access: 'read_write')
    ticket = bulk_ticket
    create(:ticket_assignment, ticket: ticket, user: outsider)
    create(:ticket_assignment, ticket: ticket, user: writer)
    NotificationSubscription.system_subscribe(user: outsider, item: ticket)

    impact = described_class.call(project: project, ticket_ids: [ticket.id], target_project: target)
    expect(impact[:move]).to eq(lost_assignments: 1, lost_subscriptions: 1)
    expect(impact).to include(count: 1, hierarchy: 0)
  end
end

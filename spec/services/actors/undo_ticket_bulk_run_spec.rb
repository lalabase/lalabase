# frozen_string_literal: true

require 'rails_helper'

# What: Actors::UndoTicketBulkRun (doc/ticket_bulk_edit_plan.md, D8).
# Type: actor spec.
# Why: the undo restores the previous values through the same change classes,
#   leaves a ticket alone that no longer carries what the run wrote and names
#   it, is a run of its own that marks the original undone, and refuses a
#   second time, after the window, and for someone else.
RSpec.describe Actors::UndoTicketBulkRun, :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:other) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let!(:tickets) { [bulk_ticket({ 'status' => 'open', 'due_date' => '2026-09-30' }), bulk_ticket({ 'status' => 'wip' })] }

  before do
    bulk_project_setup
    create(:membership, user: other, organisation: organisation, role: create(:role, organisation: organisation))
  end
  after { ActsAsTenant.current_tenant = nil }

  let(:original) do
    Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                    changes: [{ 'field' => 'status', 'value' => 'wip' }, { 'field' => 'due_date', 'clear' => true }]).resource
  end

  it 'puts the previous values back, as a run of its own, and marks the original undone' do
    original
    expect(tickets.first.reload.custom_attributes).to eq({ 'status' => 'wip' })

    result = described_class.call(run: original, current_user: writer)

    expect(result).to be_success
    undo = result.resource
    expect(undo.undo_of).to eq(original)
    expect(undo.changed_count).to eq(2)
    expect(tickets.first.reload.custom_attributes).to eq({ 'status' => 'open', 'due_date' => '2026-09-30' })
    expect(tickets.last.reload.custom_attributes['status']).to eq('wip')
    expect(original.reload).to be_undone
    expect(Activity.find_by(trackable: project, action: 'tickets_bulk_undone')).to be_present
  end

  # The person the run added was deactivated since: no longer offered, but the
  # undo only takes them off again and must not be refused for it.
  it 'takes back an assignment of a person deactivated since' do
    gone = create(:user)
    bulk_member(gone)
    added = Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                            changes: [{ 'field' => 'assignees', 'add' => [gone.id] }]).resource
    Membership.find_by!(user: gone, organisation: organisation).update!(active: false)

    result = described_class.call(run: added, current_user: writer)

    expect(result).to be_success
    expect(tickets.map { |ticket| ticket.reload.assignees.to_a }).to all(be_empty)
  end

  # The run took a person off who was deactivated since. Putting them back is
  # not allowed any more; the undo leaves them off and puts back the rest
  # (the status of the same tickets), instead of failing every ticket.
  it 'puts back the rest when a person the run removed may not be assigned any more' do
    gone = create(:user)
    membership = bulk_member(gone)
    tickets.each { |ticket| ticket.ticket_assignments.create!(user: gone) }
    removed = Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                              changes: [{ 'field' => 'status', 'value' => 'wip' },
                                                        { 'field' => 'assignees', 'remove' => [gone.id] }]).resource
    membership.update!(active: false)

    result = described_class.call(run: removed, current_user: writer)

    expect(result).to be_success
    expect(result.resource.changed_count).to eq(2)
    expect(tickets.first.reload.custom_attributes['status']).to eq('open')
    expect(tickets.map { |ticket| ticket.reload.assignees.to_a }).to all(be_empty)
  end

  it 'puts back the rest when a watcher the run removed may not follow any more' do
    gone = create(:user)
    membership = bulk_member(gone)
    ticket = tickets.first
    Current.set(user: writer) { NotificationSubscription.subscribe_other(user: gone, item: ticket, subscribed_by: writer) }
    removed = Actors::ApplyTicketChanges.call(project: project, ticket_ids: [ticket.id], current_user: writer,
                                              changes: [{ 'field' => 'status', 'value' => 'wip' },
                                                        { 'field' => 'watchers', 'remove' => [gone.id] }]).resource
    membership.update!(active: false)

    result = described_class.call(run: removed, current_user: writer)

    expect(result).to be_success
    expect(ticket.reload.custom_attributes['status']).to eq('open')
    expect(NotificationSubscription.where(subscribable: ticket, user: gone)).not_to exist
  end

  # The person the run removed lost the membership altogether since: no member,
  # not on the ticket, no subscription left. The run itself names them, so its
  # undo accepts them, leaves them off, and puts the status back.
  it 'puts back the rest when a person the run removed has no membership any more' do
    gone = create(:user)
    membership = bulk_member(gone)
    tickets.each { |ticket| ticket.ticket_assignments.create!(user: gone) }
    removed = Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                              changes: [{ 'field' => 'status', 'value' => 'wip' },
                                                        { 'field' => 'assignees', 'remove' => [gone.id] }]).resource
    membership.destroy!

    result = described_class.call(run: removed, current_user: writer)

    expect(result).to be_success
    expect(tickets.first.reload.custom_attributes['status']).to eq('open')
    expect(tickets.map { |ticket| ticket.reload.assignees.to_a }).to all(be_empty)
  end

  # Whoever the run did not touch stays as they are, also a person who may not
  # be assigned or follow any more.
  it 'leaves an untouched, deactivated assignee on the ticket' do
    stays = create(:user)
    stays_membership = bulk_member(stays)
    added = create(:user)
    bulk_member(added)
    ticket = tickets.first
    ticket.ticket_assignments.create!(user: stays)
    stays_membership.update!(active: false)
    run_record = Actors::ApplyTicketChanges.call(project: project, ticket_ids: [ticket.id], current_user: writer,
                                                 changes: [{ 'field' => 'assignees', 'add' => [added.id] }]).resource

    expect(described_class.call(run: run_record, current_user: writer)).to be_success
    expect(ticket.reload.assignees.to_a).to eq([stays])
  end

  it 'leaves an untouched, deactivated watcher on the ticket' do
    stays = create(:user)
    stays_membership = bulk_member(stays)
    added = create(:user)
    bulk_member(added)
    ticket = tickets.first
    Current.set(user: writer) { NotificationSubscription.subscribe_other(user: stays, item: ticket, subscribed_by: writer) }
    stays_membership.update!(active: false)
    run_record = Actors::ApplyTicketChanges.call(project: project, ticket_ids: [ticket.id], current_user: writer,
                                                 changes: [{ 'field' => 'watchers', 'add' => [added.id] }]).resource

    expect(described_class.call(run: run_record, current_user: writer)).to be_success
    followers = NotificationSubscription.where(subscribable: ticket, mode: :follow).pluck(:user_id)
    expect(followers).to include(stays.id)
    expect(followers).not_to include(added.id)
  end

  # The run's people and no one else: a deactivated member the run never named
  # is not offered to its undo.
  it 'offers the undo the people of the run only' do
    gone = create(:user)
    bulk_member(gone).update!(active: false)
    other_gone = create(:user)
    bulk_member(other_gone).update!(active: false)
    run_record = TicketBulkRun.create!(organisation: organisation, project: project, user: writer,
                                       change_list: [{ 'field' => 'assignees', 'kind' => 'multi', 'add' => [gone.id], 'remove' => [] }])

    assignees = Tickets::BulkFields.for_run(run: run_record, user: writer).find { |field| field.key == 'assignees' }
    offered = assignees.options.pluck(:value)

    expect(offered).to include(gone.id)
    expect(offered).not_to include(other_gone.id)
  end

  # A change list the catalogue refuses is a failure of the call with its
  # code, never an exception.
  it 'answers a change list the catalogue refuses as a failure' do
    original
    original.update_column(:change_list, [{ 'field' => 'assignees', 'kind' => 'multi', 'add' => [SecureRandom.uuid], 'remove' => [] }])

    result = described_class.call(run: original, current_user: writer)

    expect(result).not_to be_success
    expect(result.code).to eq(:value_not_allowed)
  end

  # A member sees only tags in use in its projects (TagPolicy::Scope). A run
  # that takes a tag off its last tickets hides the tag from that member's
  # catalogue; the undo must still read its own run (review of #926).
  context 'when a member removed a tag from its last tickets' do
    let(:member) { create(:user) }

    before do
      create(:membership, user: member, organisation: organisation, active: true,
                          role: create(:role, organisation: organisation, title: 'Member', is_default: true))
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
      tickets.each { |ticket| ticket.tag_list = ['einzeln'] }
    end

    it 'puts the tag back' do
      run = Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: member,
                                            changes: [{ 'field' => 'tags', 'remove' => ['einzeln'] }])
      expect(run).to be_success
      expect(tickets.map { |t| t.reload.tag_list }).to all(be_empty)

      result = described_class.call(run: run.resource, current_user: member)

      expect(result).to be_success
      expect(tickets.map { |t| t.reload.tag_list }).to all(eq(['einzeln']))
    end
  end

  it 'leaves a ticket alone that was changed since, and names it' do
    original
    # reload: the in-memory ticket predates the run and would see no change to save
    tickets.first.reload.update!(custom_attributes: tickets.first.custom_attributes.merge('status' => 'open'))

    result = described_class.call(run: original, current_user: writer)

    expect(result).to be_success
    expect(result.resource.changed_count).to eq(1)
    expect(result.resource.failed_results.values.first).to include('error' => 'changed_since')
    expect(tickets.first.reload.custom_attributes).to eq({ 'status' => 'open' }), 'the date is not put back on a ticket somebody touched'
  end

  it 'refuses a second time, someone else, and after the window' do
    original
    expect(described_class.call(run: original, current_user: other).code).to eq(:not_undoable)
    expect(described_class.call(run: original, current_user: writer)).to be_success
    expect(described_class.call(run: original.reload, current_user: writer).code).to eq(:not_undoable)

    late = Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                           changes: [{ 'field' => 'status', 'value' => 'open' }]).resource
    late.update_column(:created_at, (TicketBulkRun::UNDO_WINDOW + 1.minute).ago)
    expect(described_class.call(run: late.reload, current_user: writer).code).to eq(:not_undoable)
  end
end

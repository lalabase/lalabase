# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::BulkSummary, the stock of the selected tickets per field
#   (doc/ticket_bulk_edit_plan.md, slice 4).
# Type: service spec.
# Why: the stock line is the basis of the decision ("bisher: in Arbeit 8 ·
#   offen 6") and the digest is the fingerprint the execute step compares
#   (D11). Every number must come from the selection, the singular case must
#   say 1, and a changed value must change the digest.
RSpec.describe Tickets::BulkSummary do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', position: 1,
                                         labels: { 'de' => 'Status' },
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'offen' } },
                                           { 'value' => 'wip', 'labels' => { 'de' => 'in Arbeit' } }
                                         ] })
    create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date', position: 2,
                                         labels: { 'de' => 'Frist' }, options: { 'deadline' => true })
    create(:ticket_attribute_definition, project: project, name: 'reviewed', field_type: 'checkbox', position: 3,
                                         labels: { 'de' => 'Geprüft' })
  end
  after { ActsAsTenant.current_tenant = nil }

  let(:fields) { Tickets::BulkFields.for(project: project, user: user, locale: :de) }

  def ticket(attrs)
    create(:ticket, project: project, organisation: organisation, creator: user, custom_attributes: attrs)
  end

  let!(:tickets) do
    [
      ticket('status' => 'wip', 'due_date' => '2026-09-30', 'reviewed' => true),
      ticket('status' => 'wip', 'due_date' => '2026-10-15', 'reviewed' => false),
      ticket('status' => 'open', 'due_date' => '2026-09-30'),
      ticket({})
    ]
  end

  subject(:summary) { described_class.call(project: project, fields: fields, ticket_ids: tickets.map(&:id)) }

  # The fields carry the reader's tag list; a summary without them would
  # have to build an unscoped one.
  it 'cannot be built without the fields' do
    expect { described_class.call(project: project, ticket_ids: tickets.map(&:id)) }.to raise_error(ArgumentError, /fields/)
  end

  it 'counts the selection' do
    expect(summary[:count]).to eq(4)
  end

  it 'counts a select by value, labelled, most common first, and the ones without' do
    status = summary[:fields]['status']

    expect(status[:values]).to eq([{ value: 'wip', label: 'in Arbeit', count: 2 }, { value: 'open', label: 'offen', count: 1 }])
    expect(status[:without]).to eq(1)
  end

  it 'counts a date as without, different, and the one date when all share it' do
    expect(summary[:fields]['due_date']).to include(without: 1, distinct: 2, only: nil)

    same = described_class.call(project: project, fields: fields, ticket_ids: [tickets[0].id, tickets[2].id])
    expect(same[:fields]['due_date']).to include(without: 0, distinct: 1, only: '2026-09-30')
  end

  it 'counts a boolean as yes, no and without' do
    expect(summary[:fields]['reviewed']).to include(yes: 1, no: 1, without: 2)
  end

  it 'answers for one ticket with ones' do
    one = described_class.call(project: project, fields: fields, ticket_ids: [tickets[0].id])

    expect(one[:count]).to eq(1)
    expect(one[:fields]['status'][:values]).to eq([{ value: 'wip', label: 'in Arbeit', count: 1 }])
  end

  it 'gives every field a digest that changes with the stock' do
    before = summary[:fields]['status'][:digest]
    expect(before).to match(/\A\h{16}\z/)

    tickets[2].update!(custom_attributes: tickets[2].custom_attributes.merge('status' => 'wip'))
    after = described_class.call(project: project, fields: fields, ticket_ids: tickets.map(&:id))[:fields]['status'][:digest]

    expect(after).not_to eq(before)
    expect(after).to eq(described_class.call(project: project, fields: fields, ticket_ids: tickets.map(&:id))[:fields]['status'][:digest])
  end

  it 'counts the multi-valued fields: tags, assignees, watchers and a multiselect' do
    tag = create(:tag, name: 'backend', organisation: organisation)
    create(:tagging, tag: tag, taggable: tickets[0])
    create(:tagging, tag: tag, taggable: tickets[1])
    other = create(:user, first_name: 'Anna', last_name: 'Berg')
    create(:membership, user: other, organisation: organisation, role: create(:admin_role, organisation: organisation))
    TicketAssignment.create!(ticket: tickets[0], user: other)
    NotificationSubscription.system_subscribe(user: other, item: tickets[1])
    NotificationSubscription.system_subscribe(user: other, item: tickets[2])
    NotificationSubscription.system_subscribe(user: user, item: tickets[2], mode: 'mute')
    create(:ticket_attribute_definition, project: project, name: 'component', field_type: 'multiselect', position: 4,
                                         labels: { 'de' => 'Komponente' },
                                         options: { 'allowed_values' => [{ 'value' => 'api', 'labels' => { 'de' => 'API' } }] })
    tickets[0].update!(custom_attributes: tickets[0].custom_attributes.merge('component' => %w[api]))

    fields = summary[:fields]
    expect(fields['tags'][:values]).to eq([{ value: 'backend', label: 'backend', count: 2 }])
    expect(fields['assignees'][:values]).to eq([{ value: other.id, label: 'Anna Berg', count: 1 }])
    # Watchers are the follow subscriptions, whoever made them: the two explicit
    # ones plus the one the assignment created (auto_subscribe_assignees); the
    # muted one on tickets[2] does not count. The creator follows every ticket
    # of theirs the same way and shows up beside Anna.
    expect(fields['watchers'][:values]).to include({ value: other.id, label: 'Anna Berg', count: 3 })
    expect(fields['watchers'][:values].map { |entry| entry[:value] }).to include(user.id)
    expect(fields['component'][:values]).to eq([{ value: 'api', label: 'API', count: 1 }])
  end

  # Deactivated: no longer offered, still on the ticket, still a name.
  it 'names a deactivated assignee instead of showing the id' do
    gone = create(:user, first_name: 'Lea', last_name: 'Leaver')
    create(:membership, user: gone, organisation: organisation, role: create(:admin_role, organisation: organisation), active: false)
    TicketAssignment.create!(ticket: tickets[0], user: gone)

    expect(summary[:fields]['assignees'][:values]).to eq([{ value: gone.id, label: 'Lea Leaver', count: 1 }])
  end

  it 'names an assignee whose membership was deleted' do
    gone = create(:user, first_name: 'Max', last_name: 'Fort')
    membership = create(:membership, user: gone, organisation: organisation, role: create(:admin_role, organisation: organisation))
    TicketAssignment.create!(ticket: tickets[0], user: gone)
    membership.destroy!

    expect(summary[:fields]['assignees'][:values]).to eq([{ value: gone.id, label: 'Max Fort', count: 1 }])
  end

  it 'ignores tickets outside the given ids' do
    other = ticket('status' => 'open')
    without_other = described_class.call(project: project, fields: fields, ticket_ids: tickets.map(&:id))

    expect(without_other[:count]).to eq(4)
    expect(without_other[:fields]['status'][:values].find { |v| v[:value] == 'open' }[:count]).to eq(1)
    expect(other).to be_persisted
  end
end

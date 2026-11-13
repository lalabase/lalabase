# frozen_string_literal: true

require 'rails_helper'

# The one write behind a row action of both inboxes. The request specs
# (inbox_row_actions_spec, all_inboxes_row_actions_spec) hold what a reader sees;
# here stands what the actor itself promises a caller.
RSpec.describe Actors::ChangeNotificationState do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }

  def notification_for(subject, state: :delivered, channel: 'in_app')
    create(:notification, recipient: user, organisation: organisation, project: project, notifiable: subject,
                          event_type: 'ticket_commented', channel: channel, state: state,
                          archived_at: state == :archived ? 1.hour.ago : nil)
  end

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    make_token_owner_a_member(user, organisation, projects: [project])
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def change(notification, to)
    described_class.call(notification: notification, change: to, current_user: user)
  end

  it 'answers with the row it changed' do
    row = notification_for(ticket)

    result = change(row, 'read')

    expect(result).to be_success
    expect(result.resource).to eq(row)
    expect(row.reload).to be_state_read
  end

  it 'refuses a change it does not know and writes nothing' do
    row = notification_for(ticket)

    result = change(row, 'destroy')

    expect(result).not_to be_success
    expect(result.code).to eq(:invalid_input)
    expect(row.reload).to be_state_delivered
  end

  it 'takes the notifications about the same subject along, and no other subject' do
    row = notification_for(ticket)
    sibling = notification_for(ticket)
    other = notification_for(ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) })

    change(row, 'archive')

    expect(sibling.reload).to be_state_archived
    expect(other.reload).to be_state_delivered
  end

  it 'gives an archived sibling without a read time one on the way back' do
    row = notification_for(ticket, state: :archived)
    sibling = notification_for(ticket, state: :archived)
    expect(sibling.read_at).to be_nil

    change(row, 'unarchive')

    expect(sibling.reload).to be_state_read
    expect(sibling.read_at).to be_present
    expect(sibling.archived_at).to be_nil
  end

  it 'leaves an unread row unread on "unarchive" and brings nothing else back' do
    row = notification_for(ticket)

    change(row, 'unarchive')

    expect(row.reload).to be_state_delivered
  end

  it 'changes only the row itself when it has no subject siblings in view' do
    row = notification_for(ticket)
    mail = notification_for(ticket, channel: 'email')

    change(row, 'read')

    expect(mail.reload).to be_state_delivered
  end

  # The caller renders from the row it handed in (the buttons of the lane head):
  # it has to know its new state without a reload.
  it 'leaves the row it was given in its new state' do
    read = notification_for(ticket)
    archived = notification_for(ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) })

    change(read, 'read')
    change(archived, 'archive')

    expect(read).to be_state_read
    expect(read.read_at).to be_present
    expect(archived).to be_state_archived
  end

  it 'reads only what is unread: an archived sibling stays archived, a read one keeps its time' do
    row = notification_for(ticket)
    archived = notification_for(ticket, state: :archived)
    read_at = 2.days.ago.change(usec: 0)
    read = notification_for(ticket, state: :read)
    read.update_columns(read_at: read_at)

    change(row, 'read')

    expect(archived.reload).to be_state_archived
    expect(read.reload.read_at).to eq(read_at)
  end
end

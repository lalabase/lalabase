# frozen_string_literal: true

require 'rails_helper'

# What: Notifications::MarkTicketRead, "this user has read this ticket".
# Why:  The user decided (30.09.2026) that a ticket view open for a moment, or an own
#       comment, clears ALL of the user's marks about that ticket: comment,
#       assignment, status change, mention. It must not touch anyone else's, another
#       ticket's, or an e-mail row, and it must go through bulk_transition! so the
#       org switcher signal follows.
RSpec.describe Notifications::MarkTicketRead do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:other_ticket) { create(:ticket, project: project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def notify(recipient:, notifiable:, event_type:, channel: 'in_app', state: 'queued')
    create(:notification, recipient: recipient, organisation: organisation, project: project, channel: channel,
                          state: state, event_type: event_type, notifiable: notifiable,
                          dedupe_fingerprint: SecureRandom.hex(8))
  end

  it 'marks every unread in-app notification of the user about the ticket, whatever its event' do
    ours = [Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
            Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
            Notifications::Constants::EVENT_TYPE_TICKET_STATUS_CHANGED,
            Notifications::Constants::EVENT_TYPE_MENTION].map do |event_type|
      notify(recipient: user, notifiable: ticket, event_type: event_type)
    end

    ids = described_class.call(user: user, ticket: ticket)

    expect(ids).to match_array(ours.map(&:id))
    rows = Notification.where(id: ours.map(&:id)).pluck(:state, :read_at)
    expect(rows).to all(match(['read', be_present]))
  end

  it 'leaves other people, other tickets and e-mail rows alone' do
    theirs = notify(recipient: other_user, notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_MENTION)
    elsewhere = notify(recipient: user, notifiable: other_ticket, event_type: Notifications::Constants::EVENT_TYPE_MENTION)
    mail = notify(recipient: user, notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                  channel: 'email')
    ours = notify(recipient: user, notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_MENTION)

    expect(described_class.call(user: user, ticket: ticket)).to eq([ours.id])
    expect(Notification.where(id: [theirs, elsewhere, mail].map(&:id)).pluck(:state)).to all(eq('queued'))
  end

  it 'returns nothing and writes nothing when the ticket has nothing unread' do
    read = notify(recipient: user, notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                  state: 'read')
    read.update_column(:read_at, 2.days.ago)

    expect(Notifications::UnreadSignals).not_to receive(:refresh_later)
    expect(described_class.call(user: user, ticket: ticket)).to eq([])
    expect(read.reload.read_at).to be_within(1.second).of(2.days.ago)
  end

  it 'refreshes the org switcher signal through bulk_transition!' do
    notify(recipient: user, notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_MENTION)

    expect(Notifications::UnreadSignals).to receive(:refresh_later).with(user.id)
    described_class.call(user: user, ticket: ticket)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What: a NEW comment marks its author's notifications about the ticket as read.
# Why:  Who answers has read it (user, 30.09.2026). Editing an old comment is not
#       reading anything new, and the broadcast waits for the commit, so no job
#       counts the state before the write.
RSpec.describe Actors::SavePost, 'marks the author\'s notifications read' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def unread_notification
    create(:notification, recipient: user, organisation: organisation, project: project, channel: 'in_app',
                          state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED,
                          notifiable: ticket, dedupe_fingerprint: SecureRandom.hex(8))
  end

  it 'marks them read when the comment is new and broadcasts them' do
    notification = unread_notification
    expect(Notifications::MarkTicketRead).to receive(:broadcast).with([notification.id])

    result = described_class.call(ticket: ticket, params: { content: 'Antwort' }, current_user: user)

    expect(result).to be_success
    expect(notification.reload.state).to eq('read')
  end

  it 'leaves them unread when an existing comment is edited' do
    post = create(:post, ticket: ticket, user: user, organisation: organisation)
    notification = unread_notification

    described_class.call(ticket: ticket, params: { content: 'Korrigiert' }, id: post.id, current_user: user)

    expect(notification.reload.state).to eq('queued')
  end
end

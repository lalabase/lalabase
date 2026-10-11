# frozen_string_literal: true

require 'rails_helper'

# Delivery asks the same area rule as the inbox (Notification.area_for): a ticket
# notification reaches only who may read tickets, a note notification only who
# may read notes. Until 2026-10-07 tickets were gated by "may see the project at
# all" and notes by the documents area, so a person left with notes alone still
# received the ticket comments they were subscribed to, mentioned in or assigned
# to. Companion of spec/services/notifications/area_rights_spec.rb (read side).
RSpec.describe Notifications::FanoutService, 'area gate', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member) { create(:user) }
  let(:actor) { create(:user) }
  let(:ticket) { create(:ticket, project: project, creator: actor) }

  let(:permission) do
    create(:project_permission, user: member, project: project, tickets_access: 'read_write',
                                notes_access: 'read_only')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = actor
    create(:membership, user: actor, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    permission
  end

  def fan_out(trackable, **activity_attrs)
    activity = create(:activity, organisation: organisation, trackable: trackable, actor: actor, **activity_attrs)
    outbox_event = create(:outbox_event, organisation: organisation, activity: activity,
                                         event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
                                         payload: activity.parameters || {})
    Prosopite.pause
    described_class.new(outbox_event).call
  ensure
    Prosopite.resume
  end

  describe 'a ticket comment to a subscriber' do
    before do
      ticket
      NotificationSubscription.create!(user: member, subscribable: ticket, mode: 'follow')
    end

    it 'reaches them while they may read tickets' do
      fan_out(ticket, action: 'post_added', key: 'ticket.post_added', parameters: { 'post_preview' => 'Hallo' })
      expect(Notification.where(recipient: member, notifiable: ticket)).to exist
    end

    it 'does not reach them with notes alone' do
      permission.update!(tickets_access: 'no_access')
      fan_out(ticket, action: 'post_added', key: 'ticket.post_added', parameters: { 'post_preview' => 'Hallo' })
      expect(Notification.where(recipient: member, notifiable: ticket)).not_to exist
    end
  end

  describe 'a note to a subscriber' do
    let(:note) { create(:note, project: project, organisation: organisation, creator: actor, create_embeddings: false) }

    before { NotificationSubscription.create!(user: member, subscribable: note, mode: 'follow') }

    def update_note
      fan_out(note, action: 'updated', key: 'note.updated', parameters: { 'title' => note.title })
    end

    it 'reaches them with the notes area, without documents' do
      update_note
      expect(Notification.where(recipient: member, notifiable: note)).to exist
    end

    it 'does not reach them with documents but without notes' do
      permission.update!(notes_access: 'no_access', documents_access: 'read_only')
      update_note
      expect(Notification.where(recipient: member, notifiable: note)).not_to exist
    end
  end
end

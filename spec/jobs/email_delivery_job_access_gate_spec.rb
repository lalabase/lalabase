# frozen_string_literal: true

require 'rails_helper'

# The gate in FanoutService decides at WRITE time. Between the moment a notification is
# written and the moment its mail actually goes out, the recipient can lose the project:
# taken off it, removed from the organisation, membership deactivated. An admin resending
# an old mail from the EmailLog view reaches this job the same way.
#
# So the job asks once more, right before the mail leaves. It asks through
# Notification.accessible_for, so this stays ONE rule with one owner.
RSpec.describe EmailDeliveryJob, 'project access gate', type: :job do
  let!(:organisation) { create(:organisation, email_subject_prefix: 'ACME') }

  # Declared here on purpose: before-hooks run in declaration order, so this has to sit
  # above the let! below, which creates tenant-scoped rows.
  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # create(:user, organisation:) already writes an active membership with no role, so the
  # recipient's only reach into the project is the ProjectPermission below. That is the
  # setup the gate is about.
  let(:recipient) { create(:user, organisation: organisation) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, title: 'Fix login bug')
    end
  end

  # with_tenant, not a bare create: ProjectPermission#auto_subscribe_user writes a
  # NotificationSubscription on commit, and that one is tenant-scoped.
  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: recipient, project: project, tickets_access: 'read_write')
    end
  end

  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: recipient,
             organisation: organisation,
             project: project,
             notifiable: ticket,
             event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
             channel: Notifications::Constants::CHANNEL_EMAIL)
    end
  end

  context 'when the recipient lost the project after the job was enqueued' do
    before do
      notification
      permission.update!(tickets_access: 'no_access')
    end

    it 'sends no mail' do
      expect(NotificationMailer).not_to receive(:ticket_assignment)

      described_class.new.perform(notification.id)
    end

    it 'writes no email log' do
      expect { described_class.new.perform(notification.id) }
        .not_to change(EmailLog, :count)
    end

    it 'leaves the notification untouched, so a later resend can still go out' do
      described_class.new.perform(notification.id)

      expect(notification.reload.state).to eq('queued')
    end
  end

  context 'when the recipient still has the project' do
    it 'goes on to deliver' do
      allow(NotificationMailer).to receive(:ticket_assignment).and_call_original

      described_class.new.perform(notification.id)

      expect(NotificationMailer).to have_received(:ticket_assignment)
    end
  end

  # A notification with no project is a system message and belongs to nobody's project
  # rights. It must not get caught by the gate.
  context 'for a notification without a project' do
    let(:system_notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification,
               recipient: recipient,
               organisation: organisation,
               project: nil,
               event_type: Notifications::Constants::EVENT_TYPE_SYSTEM_MESSAGE,
               channel: Notifications::Constants::CHANNEL_EMAIL)
      end
    end

    # Asserted at the gate's own boundary (the job writes the EmailLog right after the
    # gate, before it hands over to the mailer) rather than at delivery, because
    # NotificationMailer#system_message reads notification.action_url, which exists
    # neither as a method nor as a column. That defect predates this branch and is
    # reported separately; tying this example to it would only make it flap.
    it 'is not blocked' do
      expect { perform_swallowing_mailer_defect(system_notification) }
        .to change(EmailLog, :count).by(1)
    end

    def perform_swallowing_mailer_defect(notification)
      described_class.new.perform(notification.id)
    rescue NoMethodError
      # See the comment above: the mailer defect is not what this example measures.
      nil
    end
  end
end

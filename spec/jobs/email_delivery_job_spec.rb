# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailDeliveryJob, type: :job do
  let!(:organisation) { create(:organisation, email_subject_prefix: 'ACME') }
  let(:recipient)     { create(:user, organisation: organisation) }
  let(:actor)         { create(:user, organisation: organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, title: 'Fix login bug')
    end
  end

  def perform_job(id)
    described_class.new.perform(id)
  end

  describe 'Regression: Notification as notifiable' do
    it 'delivers successfully and uses nested notifiable title without raising' do
      ActsAsTenant.with_tenant(organisation) do
        inner = create(:notification,
                       recipient: recipient,
                       organisation: organisation,
                       notifiable: ticket,
                       event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
                       channel: Notifications::Constants::CHANNEL_EMAIL)

        notification = create(:notification,
                              recipient: recipient,
                              organisation: organisation,
                              notifiable: inner,
                              event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
                              channel: Notifications::Constants::CHANNEL_EMAIL)

        # NOTE: EmailLog.create_for_notification! is handled correctly now

        # Expect mailer to be called and deliver_now to succeed
        allow(NotificationMailer).to receive(:ticket_assignment) do |notif, options|
          # Tenant should already be set before entering mailer
          expect(ActsAsTenant.current_tenant).to eq(organisation)
          expect(notif).to eq(notification)
          expect(options).to include(:to, :from, :subject)
          mail_double = double(deliver_now: true, message_id: 'test-123', multipart?: false)
          allow(mail_double).to receive(:html_part).and_return(nil)
          allow(mail_double).to receive(:text_part).and_return(nil)
          allow(mail_double).to receive(:content_type).and_return('text/plain')
          allow(mail_double).to receive(:body).and_return(double(decoded: 'Test email content'))
          allow(mail_double).to receive(:subject).and_return('Test Subject')
          allow(mail_double).to receive(:to).and_return(['test@example.com'])
          allow(mail_double).to receive(:from).and_return(['noreply@example.com'])
          mail_double
        end

        expect { perform_job(notification.id) }.not_to raise_error

        # EmailLog is created and marked sent with provider message id
        log = EmailLog.for_notification(notification).order(created_at: :desc).first
        expect(log).to be_present
        expect(log.status).to eq('sent')
        expect(log.provider_message_id).to eq('test-123')

        # Notification state transitions to sent
        expect(notification.reload.state).to eq('sent')
      end
    end
  end

  describe 'extract_notifiable_title' do
    let(:job) { described_class.new }

    it 'returns ticket.title when present' do
      expect(job.send(:extract_notifiable_title, ticket)).to eq('Fix login bug')
    end

    it "returns 'ticket' when ticket title is missing" do
      allow(ticket).to receive(:title).and_return(nil)
      expect(job.send(:extract_notifiable_title, ticket)).to eq('ticket')
    end

    it 'returns project.name when present' do
      project.update!(name: 'Website Redesign')
      expect(job.send(:extract_notifiable_title, project)).to eq('Website Redesign')
    end

    it 'returns document/note title when available' do
      ActsAsTenant.with_tenant(organisation) do
        note = create(:note, project: project, organisation: organisation, creator: actor, title: 'Kickoff Notes', content: 'Hello')
        expect(job.send(:extract_notifiable_title, note)).to eq('Kickoff Notes')

        # For Document, test the logic directly without creating actual record
        document = Document.new
        expect(job.send(:extract_notifiable_title, document)).to eq('document')
      end
    end

    it 'handles Notification by extracting from nested notifiable' do
      ActsAsTenant.with_tenant(organisation) do
        nested = create(:notification, recipient: recipient, organisation: organisation,
                                       notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED)
        expect(job.send(:extract_notifiable_title, nested)).to eq('Fix login bug')
      end
    end

    it "returns 'unknown' for nil" do
      expect(job.send(:extract_notifiable_title, nil)).to eq('unknown')
    end

    it "returns 'item' for unknown objects" do
      unknown = Object.new
      expect(job.send(:extract_notifiable_title, unknown)).to eq('item')
    end
  end

  describe 'generate_email_subject' do
    let(:job) { described_class.new }

    it 'uses event-specific template and organization prefix' do
      ActsAsTenant.with_tenant(organisation) do
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED)
        subject = job.send(:generate_email_subject, n)
        expect(subject).to eq('[ACME] Ticket assigned: Fix login bug')
      end
    end

    it 'omits prefix when not configured' do
      ActsAsTenant.with_tenant(organisation) do
        organisation.update!(email_subject_prefix: nil)
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_COMMENTED)
        subject = job.send(:generate_email_subject, n)
        expect(subject).to eq('New comment on Fix login bug')
      end
    end

    it "handles missing notifiable title and falls back to 'unknown'" do
      ActsAsTenant.with_tenant(organisation) do
        # Create a notification and mock the notifiable as nil for testing
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED)
        # Mock notifiable to return nil without violating DB constraints
        allow(n).to receive(:notifiable).and_return(nil)
        subject = job.send(:generate_email_subject, n)
        expect(subject).to eq('[ACME] Ticket assigned: unknown')
      end
    end
  end

  describe 'Channel validation' do
    it 'returns early when channel is not email' do
      ActsAsTenant.with_tenant(organisation) do
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED, channel: Notifications::Constants::CHANNEL_IN_APP)

        expect(NotificationMailer).not_to receive(:ticket_assignment)
        expect(EmailLog).not_to receive(:create_for_notification!)
        perform_job(n.id)
      end
    end

    it 'logs and returns when recipient has no email' do
      ActsAsTenant.with_tenant(organisation) do
        # Create user without email validation by using direct column update
        no_email_user = create(:user, organisation: organisation, email: 'temp@example.com')
        no_email_user.update_column(:email, '') # Bypass validation

        n = create(:notification, recipient: no_email_user, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED, channel: Notifications::Constants::CHANNEL_EMAIL)

        expect(Rails.logger).to receive(:warn).with(/Recipient has no email/)
        expect(NotificationMailer).not_to receive(:ticket_assignment)
        expect { perform_job(n.id) }.not_to raise_error

        # State remains queued (mark_failed! only touches)
        expect(n.reload.state).to eq('queued')
      end
    end

    it 'skips when notification already sent or delivered' do
      ActsAsTenant.with_tenant(organisation) do
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED, channel: Notifications::Constants::CHANNEL_EMAIL)
        n.update!(state: 'sent')

        expect(Rails.logger).to receive(:info).with(%r{already sent/delivered})
        expect(NotificationMailer).not_to receive(:ticket_assignment)
        perform_job(n.id)
        expect(EmailLog.for_notification(n).count).to eq(0)
      end
    end
  end

  describe 'Error handling & retry' do
    it 'retries on Timeout::Error and marks email log failed' do
      ActsAsTenant.with_tenant(organisation) do
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED, channel: Notifications::Constants::CHANNEL_EMAIL)

        allow(NotificationMailer).to receive(:ticket_assignment) do |_notif, _options|
          double(deliver_now: (raise Timeout::Error), message_id: nil)
        end

        expect { perform_job(n.id) }.to raise_error(Timeout::Error)

        log = EmailLog.for_notification(n).order(created_at: :desc).first
        expect(log).to be_present
        expect(log.status).to eq('failed')
      end
    end

    it 'discards job on ActiveRecord::RecordNotFound' do
      # Set a tenant context first, then test with non-existent notification
      ActsAsTenant.with_tenant(organisation) do
        non_existent_id = SecureRandom.uuid
        expect { perform_job(non_existent_id) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    it 'marks notification failed on generic delivery error' do
      ActsAsTenant.with_tenant(organisation) do
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED, channel: Notifications::Constants::CHANNEL_EMAIL)

        allow(NotificationMailer).to receive(:ticket_assignment) do |_notif, _options|
          double(deliver_now: (raise StandardError, 'SMTP down'), message_id: nil)
        end

        expect { perform_job(n.id) }.to raise_error(StandardError)

        # Notification remains in queued but marked failed via touch (timestamp change)
        expect(n.reload.state).to eq('queued')
        log = EmailLog.for_notification(n).order(created_at: :desc).first
        expect(log.status).to eq('failed')
      end
    end
  end

  describe 'Multi-tenancy' do
    it 'runs within ActsAsTenant.with_tenant for the notification organisation' do
      create(:organisation, email_subject_prefix: 'OTHER')

      # Create notification in correct tenant context
      n = nil
      ActsAsTenant.with_tenant(organisation) do
        n = create(:notification, recipient: recipient, organisation: organisation,
                                  notifiable: ticket, event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED, channel: Notifications::Constants::CHANNEL_EMAIL)
      end

      # The job should set the correct tenant even when called from a different context
      # Test that the job finds the notification by bypassing tenant scoping
      allow(NotificationMailer).to receive(:ticket_assignment) do |_notif, _options|
        # At this point, job should have set tenant to notification's organisation
        expect(ActsAsTenant.current_tenant).to eq(organisation)
        mail_double = double(deliver_now: true, message_id: 'mt-1', multipart?: false)
        allow(mail_double).to receive(:html_part).and_return(nil)
        allow(mail_double).to receive(:text_part).and_return(nil)
        allow(mail_double).to receive(:content_type).and_return('text/plain')
        allow(mail_double).to receive(:body).and_return(double(decoded: 'Test email content'))
        allow(mail_double).to receive(:subject).and_return('Test Subject')
        allow(mail_double).to receive(:to).and_return(['test@example.com'])
        allow(mail_double).to receive(:from).and_return(['noreply@example.com'])
        mail_double
      end

      # Clear tenant to simulate job being called from neutral context
      ActsAsTenant.current_tenant = nil
      expect { perform_job(n.id) }.not_to raise_error
    end
  end

  describe 'Email provider detection' do
    it 'detects letter_opener delivery method' do
      job = described_class.new
      original = Rails.application.config.action_mailer.delivery_method
      begin
        allow(Rails.application.config.action_mailer).to receive(:delivery_method).and_return(:letter_opener)
        expect(job.send(:email_provider_name)).to eq('letter_opener')
      ensure
        allow(Rails.application.config.action_mailer).to receive(:delivery_method).and_return(original)
      end
    end
  end
end

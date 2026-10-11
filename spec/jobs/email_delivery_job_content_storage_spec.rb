# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailDeliveryJob, type: :job do
  describe 'Email Content Storage' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation, email: 'test@example.com') }
    let(:ticket) { create(:ticket, organisation: organisation) }
    let(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification,
               recipient: user,
               organisation: organisation,
               notifiable: ticket,
               event_type: 'ticket_assigned',
               channel: 'email',
               state: 'queued',
               payload: { assignee_name: 'John Doe' })
      end
    end

    describe 'stores email content after sending' do
      it 'saves HTML content, text content, and preview in EmailLog' do
        # Mock the mailer to return a multipart email
        mail_double = double(
          message_id: 'test_message_id',
          subject: 'Test Subject',
          to: ['test@example.com'],
          from: ['noreply@example.com'],
          multipart?: true
        )

        # Mock HTML part
        html_part = double(
          body: double(decoded: '<html><body><h1>Test Email</h1><p>This is the HTML content</p></body></html>')
        )

        # Mock text part
        text_part = double(
          body: double(decoded: 'Test Email\n\nThis is the text content')
        )

        allow(mail_double).to receive(:html_part).and_return(html_part)
        allow(mail_double).to receive(:text_part).and_return(text_part)
        allow(mail_double).to receive(:content_type).and_return('multipart/alternative')
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Run the job
        EmailDeliveryJob.perform_now(notification.id)

        # Check that EmailLog was created with content
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.body_html).to eq('<html><body><h1>Test Email</h1><p>This is the HTML content</p></body></html>')
          expect(email_log.body_text).to eq('Test Email\n\nThis is the text content')
          expect(email_log.body_preview).to be_present
          expect(email_log.body_preview).to include('Test Email')
          expect(email_log.subject).to eq('Test Subject')
          expect(email_log.recipient_email).to eq('test@example.com')
        end
      end

      it 'handles plain text only emails' do
        # Mock a plain text email
        mail_double = double(
          message_id: 'test_message_id',
          subject: 'Plain Text Email',
          to: ['test@example.com'],
          from: ['noreply@example.com'],
          multipart?: false,
          content_type: 'text/plain',
          body: double(decoded: 'This is a plain text email with important information')
        )

        allow(mail_double).to receive(:html_part).and_return(nil)
        allow(mail_double).to receive(:text_part).and_return(nil)
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Run the job
        EmailDeliveryJob.perform_now(notification.id)

        # Check that EmailLog was created with text content
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.body_html).to be_nil
          expect(email_log.body_text).to eq('This is a plain text email with important information')
          expect(email_log.body_preview).to eq('This is a plain text email with important information')
        end
      end

      it 'handles HTML only emails' do
        # Mock an HTML email
        mail_double = double(
          message_id: 'test_message_id',
          subject: 'HTML Email',
          to: ['test@example.com'],
          from: ['noreply@example.com'],
          multipart?: false,
          content_type: 'text/html',
          body: double(decoded: '<div><h1>Welcome</h1><p>This is an HTML email</p></div>')
        )

        allow(mail_double).to receive(:html_part).and_return(nil)
        allow(mail_double).to receive(:text_part).and_return(nil)
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Run the job
        EmailDeliveryJob.perform_now(notification.id)

        # Check that EmailLog was created with HTML content
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.body_html).to eq('<div><h1>Welcome</h1><p>This is an HTML email</p></div>')
          expect(email_log.body_text).to be_nil
          expect(email_log.body_preview).to be_present
          expect(email_log.body_preview).to include('Welcome')
        end
      end

      it 'truncates preview to 500 characters' do
        long_text = 'A' * 600

        mail_double = double(
          message_id: 'test_message_id',
          subject: 'Long Email',
          to: ['test@example.com'],
          from: ['noreply@example.com'],
          multipart?: false,
          content_type: 'text/plain',
          body: double(decoded: long_text)
        )

        allow(mail_double).to receive(:html_part).and_return(nil)
        allow(mail_double).to receive(:text_part).and_return(nil)
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Run the job
        EmailDeliveryJob.perform_now(notification.id)

        # Check that preview was truncated
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.body_preview.length).to eq(500)
          expect(email_log.body_preview).to end_with('...')
        end
      end

      it 'strips HTML tags from preview' do
        mail_double = double(
          message_id: 'test_message_id',
          subject: 'HTML Email',
          to: ['test@example.com'],
          from: ['noreply@example.com'],
          multipart?: false,
          content_type: 'text/html',
          body: double(decoded: '<html><body><h1>Important</h1><p>This is <strong>very</strong> important</p></body></html>')
        )

        allow(mail_double).to receive(:html_part).and_return(nil)
        allow(mail_double).to receive(:text_part).and_return(nil)
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Run the job
        EmailDeliveryJob.perform_now(notification.id)

        # Check that HTML tags were stripped from preview
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.body_preview).not_to include('<')
          expect(email_log.body_preview).not_to include('>')
          expect(email_log.body_preview).to include('Important')
          expect(email_log.body_preview).to include('This is very important')
        end
      end

      it 'stores metadata correctly' do
        mail_double = double(
          message_id: 'unique_message_id_123',
          subject: 'Metadata Test',
          to: ['recipient@example.com'],
          from: ['sender@example.com'],
          multipart?: false,
          content_type: 'text/plain',
          body: double(decoded: 'Test email')
        )

        allow(mail_double).to receive(:html_part).and_return(nil)
        allow(mail_double).to receive(:text_part).and_return(nil)
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Run the job
        EmailDeliveryJob.perform_now(notification.id)

        # Check metadata
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.provider_message_id).to eq('unique_message_id_123')
          expect(email_log.metadata['from']).to eq('sender@example.com')
          expect(email_log.metadata['subject']).to eq('Metadata Test')
          expect(email_log.metadata['message_id']).to eq('unique_message_id_123')
        end
      end
    end

    describe 'handles errors gracefully' do
      it 'continues even if content extraction fails' do
        # Mock a mail object that throws errors
        mail_double = double(
          message_id: 'test_message_id',
          subject: 'Error Test',
          to: ['test@example.com'],
          from: ['noreply@example.com']
        )

        allow(mail_double).to receive(:multipart?).and_raise(StandardError, 'Multipart check failed')
        allow(mail_double).to receive(:html_part).and_raise(StandardError, 'HTML extraction failed')
        allow(mail_double).to receive(:text_part).and_raise(StandardError, 'Text extraction failed')
        allow(mail_double).to receive(:content_type).and_raise(StandardError, 'Content type failed')
        allow(mail_double).to receive(:body).and_raise(StandardError, 'Body extraction failed')
        allow(mail_double).to receive(:deliver_now).and_return(mail_double)

        allow(NotificationMailer).to receive(:ticket_assignment).and_return(mail_double)
        allow(NotificationMailer).to receive(:generic_notification).and_return(mail_double)

        # Job should not raise error
        expect do
          EmailDeliveryJob.perform_now(notification.id)
        end.not_to raise_error

        # EmailLog should still be created
        ActsAsTenant.with_tenant(organisation) do
          email_log = EmailLog.find_by(notification: notification)

          expect(email_log).to be_present
          expect(email_log.status).to eq('sent')
          # Content fields will be nil due to errors
          expect(email_log.body_html).to be_nil
          expect(email_log.body_text).to be_nil
        end
      end
    end
  end
end

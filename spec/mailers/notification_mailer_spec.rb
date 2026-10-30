# frozen_string_literal: true

require 'rails_helper'

# Covers code-index and bulk-ticket mailer actions. Subjects and bodies must
# render in DE and EN with no "translation missing" fragment.
RSpec.describe NotificationMailer, type: :mailer do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:recipient)    { create(:user, email: 'dev@example.com') }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', connected_by_user: recipient)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def notification(event_type)
    Notification.create!(
      organisation: organisation, recipient: recipient, notifiable: repository, project: project,
      event_type: event_type, channel: 'email',
      payload: { 'full_name' => 'acme/backend', 'outcome' => event_type.sub('index_', '') },
      group_key: "gk-#{event_type}", dedupe_fingerprint: "fp-#{event_type}-#{SecureRandom.hex(4)}"
    )
  end

  describe '#index_completed' do
    %i[de en].each do |locale|
      it "renders subject + body in #{locale} with no missing translations" do
        I18n.with_locale(locale) do
          mail = described_class.index_completed(notification('index_completed'))
          expect(mail.subject).to include('acme/backend')
          expect(mail.body.encoded).to include('acme/backend')
          expect(mail.body.encoded).not_to include('translation missing')
        end
      end
    end

    it 'is addressed to the recipient' do
      expect(described_class.index_completed(notification('index_completed')).to).to eq(['dev@example.com'])
    end

    # The contact address is only shown to others (User::EmailDisplay); Lalabase
    # never mails to it, whatever the member chose.
    it 'goes to the login address, also when the member shows a contact address' do
      recipient.update!(email_visibility: 'contact', contact_email: 'dev.team@example.com')

      expect(described_class.index_completed(notification('index_completed')).to).to eq(['dev@example.com'])
    end
  end

  describe '#tickets_bulk_changed' do
    %w[tickets_bulk_changed tickets_bulk_moved tickets_bulk_deleted].each do |event_type|
      %i[de en].each do |locale|
        it "renders HTML and text for #{event_type} in #{locale}" do
          bulk_notification = Notification.create!(
            organisation: organisation, recipient: recipient, notifiable: project, project: project,
            event_type: event_type, channel: 'email',
            payload: { 'parameters' => { 'count' => 3, 'ticket_numbers' => [101, 102], 'changes' => 'Status' } },
            group_key: "gk-#{event_type}", dedupe_fingerprint: "fp-#{event_type}-#{SecureRandom.hex(4)}"
          )

          I18n.with_locale(locale) do
            mail = described_class.tickets_bulk_changed(bulk_notification)

            expect(mail.to).to eq(['dev@example.com'])
            expect(mail.subject).to include(I18n.t("notification_mailer.#{event_type}.subject", count: 3))
            [mail.html_part, mail.text_part].each do |part|
              expect(part).to be_present
              expect(part.body.decoded).to include('#101', '#102')
              expect(part.body.decoded).to include(bulk_notification.id)
              expect(part.body.decoded).not_to match(/translation missing/i)
            end
          end
        end
      end
    end
  end

  describe '#index_failed' do
    before { repository.project_index.update!(status: 'failed', error_message: 'GitHub 401: bad token') }

    %i[de en].each do |locale|
      it "renders subject + body in #{locale} with no missing translations" do
        I18n.with_locale(locale) do
          mail = described_class.index_failed(notification('index_failed'))
          expect(mail.subject).to include('acme/backend')
          expect(mail.body.encoded).not_to include('translation missing')
        end
      end
    end

    # The error text is read from the index (already token-scrubbed by
    # fail_index!), proving the failure email is actionable.
    it 'includes the scrubbed error message from the index' do
      mail = described_class.index_failed(notification('index_failed'))
      expect(mail.body.encoded).to include('GitHub 401: bad token')
    end

    it 'renders cleanly when the index has no error_message (no error block, no crash)' do
      repository.project_index.update!(status: 'failed', error_message: nil)
      mail = described_class.index_failed(notification('index_failed'))
      expect(mail.body.encoded).not_to include('translation missing')
      expect(mail.to).to eq(['dev@example.com'])
    end
  end

  # The REAL delivered subject is built by EmailDeliveryJob (EMAIL_SUBJECT_TEMPLATES
  # + extract_notifiable_title) and passed as options[:subject], NOT the mailer's
  # own i18n subject. Regression for the "Code index ready: item" bug — the repo
  # full_name must survive that pipeline.
  describe 'delivered subject (EmailDeliveryJob pipeline)' do
    it 'includes the repository full_name, not a generic placeholder' do
      subject = EmailDeliveryJob.new.send(:generate_email_subject, notification('index_completed'))
      expect(subject).to include('acme/backend')
      expect(subject).not_to include('item')
    end
  end
end

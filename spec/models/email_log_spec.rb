# frozen_string_literal: true

# == Schema Information
#
# Table name: email_logs
#
#  id                   :uuid             not null, primary key
#  body_html_compressed :binary
#  body_preview         :text
#  body_text            :text
#  bounce_type          :string
#  bounced_at           :datetime
#  can_retry            :boolean          default(TRUE)
#  click_count          :integer          default(0)
#  clicked_at           :datetime
#  delivered_at         :datetime
#  failed_at            :datetime
#  failure_reason       :text
#  lock_version         :integer          default(0), not null
#  metadata             :jsonb            not null
#  open_count           :integer          default(0)
#  opened_at            :datetime
#  recipient_email      :string
#  retry_count          :integer          default(0)
#  sent_at              :datetime
#  status               :integer          default("queued"), not null
#  subject              :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  notification_id      :uuid             not null
#  organisation_id      :uuid             not null
#  provider_message_id  :string
#  resent_from_id       :uuid
#
# Indexes
#
#  idx_email_logs_dashboard                         (organisation_id,status,created_at)
#  idx_email_logs_provider_msg                      (provider_message_id) WHERE (provider_message_id IS NOT NULL)
#  index_email_logs_on_notification_id_and_status   (notification_id,status)
#  index_email_logs_on_organisation_id_and_sent_at  (organisation_id,sent_at)
#  index_email_logs_on_organisation_id_and_status   (organisation_id,status)
#  index_email_logs_on_recipient_email              (recipient_email)
#  index_email_logs_on_resent_from_id               (resent_from_id)
#  index_email_logs_on_sent_at                      (sent_at)
#  index_email_logs_on_status_and_created_at        (status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (notification_id => notifications.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (resent_from_id => email_logs.id)
#
require 'rails_helper'
require 'support/email_log_test_helper'

RSpec.describe EmailLog, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation, channel: 'email')
    end
  end

  def build_log(*traits, **attrs)
    ActsAsTenant.with_tenant(organisation) do
      build(:email_log, *traits, notification: notification, organisation: organisation, **attrs)
    end
  end

  def create_log(*traits, **attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:email_log, *traits, notification: notification, organisation: organisation, **attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------------------
  describe 'associations' do
    subject { build_log }

    it { is_expected.to belong_to(:notification) }
    it { is_expected.to belong_to(:organisation) }
  end

  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------
  describe 'validations' do
    it 'is valid with valid attributes' do
      log = build_log
      expect(log).to be_valid
    end

    it 'requires notification' do
      with_tenant(organisation) do
        log = build(:email_log, notification: nil, organisation: organisation)
        expect(log).not_to be_valid
        expect(log.errors[:notification]).to be_present
      end
    end

    it 'requires status' do
      log = build_log
      log.status = nil
      expect(log).not_to be_valid
      expect(log.errors[:status]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # Enums
  # ---------------------------------------------------------------------------
  describe 'enums' do
    it 'defines all expected status values' do
      expected = %w[queued sent delivered bounced complaint opened clicked failed deferred unsubscribed]
      expect(described_class.statuses.keys).to match_array(expected)
    end

    it 'defaults status to queued' do
      log = build_log
      expect(log.status).to eq('queued')
    end

    it 'generates prefixed predicate methods' do
      log = build_log(status: :sent)
      expect(log.status_sent?).to be true
      expect(log.status_queued?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  describe 'scopes' do
    describe '.successful' do
      it 'includes sent, delivered, opened, clicked' do
        with_tenant(organisation) do
          sent = create_log(status: :sent)
          delivered = create_log(status: :delivered)
          opened   = create_log(status: :opened)
          clicked  = create_log(status: :clicked)
          _bounced = create_log(status: :bounced)
          _failed  = create_log(status: :failed)

          result = described_class.successful
          expect(result).to contain_exactly(sent, delivered, opened, clicked)
        end
      end
    end

    describe '.failed_delivery' do
      it 'includes bounced, complaint, failed' do
        with_tenant(organisation) do
          bounced   = create_log(status: :bounced)
          complaint = create_log(status: :complaint)
          failed    = create_log(status: :failed)
          _sent     = create_log(status: :sent)

          result = described_class.failed_delivery
          expect(result).to contain_exactly(bounced, complaint, failed)
        end
      end
    end

    describe '.recent' do
      it 'orders by created_at descending' do
        with_tenant(organisation) do
          old_log = create_log
          old_log.update_columns(created_at: 2.days.ago)
          new_log = create_log

          expect(described_class.recent.first).to eq(new_log)
          expect(described_class.recent.last).to eq(old_log)
        end
      end
    end

    describe '.for_notification' do
      it 'filters by notification' do
        with_tenant(organisation) do
          other_notification = create(:notification, recipient: user, organisation: organisation)
          matching = create_log
          _other   = create(:email_log, notification: other_notification, organisation: organisation)

          expect(described_class.for_notification(notification)).to contain_exactly(matching)
        end
      end
    end

    describe '.within_days' do
      it 'includes logs within the specified day range' do
        with_tenant(organisation) do
          recent_log = create_log
          old_log = create_log
          old_log.update_columns(created_at: 10.days.ago)

          result = described_class.within_days(7)
          expect(result).to include(recent_log)
          expect(result).not_to include(old_log)
        end
      end

      it 'excludes logs exactly at the boundary' do
        with_tenant(organisation) do
          boundary_log = create_log
          boundary_log.update_columns(created_at: 7.days.ago)

          # > 7.days.ago means strictly after, so exactly 7 days is excluded
          expect(described_class.within_days(7)).not_to include(boundary_log)
        end
      end
    end

    describe '.today' do
      it 'includes only logs from today' do
        with_tenant(organisation) do
          today_log = create_log
          yesterday_log = create_log
          yesterday_log.update_columns(created_at: 1.day.ago)

          result = described_class.today
          expect(result).to include(today_log)
          expect(result).not_to include(yesterday_log)
        end
      end
    end

    describe '.this_week' do
      it 'includes logs from the last 7 days' do
        with_tenant(organisation) do
          recent = create_log
          old = create_log
          old.update_columns(created_at: 10.days.ago)

          result = described_class.this_week
          expect(result).to include(recent)
          expect(result).not_to include(old)
        end
      end
    end

    describe '.this_month' do
      it 'includes logs from the last month' do
        with_tenant(organisation) do
          recent = create_log
          old = create_log
          old.update_columns(created_at: 2.months.ago)

          result = described_class.this_month
          expect(result).to include(recent)
          expect(result).not_to include(old)
        end
      end
    end

    describe '.by_status' do
      it 'groups counts by status' do
        with_tenant(organisation) do
          create_log(status: :sent)
          create_log(status: :sent)
          create_log(status: :bounced)

          result = described_class.by_status
          expect(result['sent']).to eq(2)
          expect(result['bounced']).to eq(1)
        end
      end
    end

    describe '.by_day' do
      it 'groups counts by date' do
        with_tenant(organisation) do
          create_log
          log2 = create_log
          log2.update_columns(created_at: 1.day.ago)

          result = described_class.by_day
          expect(result.keys.size).to eq(2)
        end
      end
    end

    describe '.by_hour' do
      it 'groups counts by hour' do
        with_tenant(organisation) do
          create_log
          result = described_class.by_hour
          expect(result.values.sum).to eq(1)
        end
      end
    end

    describe 'eager loading scopes' do
      it '.with_notification loads notification' do
        with_tenant(organisation) do
          create_log
          logs = described_class.with_notification.to_a
          # Verify no N+1 by accessing association
          expect { logs.map { |l| l.notification.id } }.not_to raise_error
        end
      end

      it '.for_admin_display loads multiple associations' do
        with_tenant(organisation) do
          create_log
          logs = described_class.for_admin_display.to_a
          expect(logs).not_to be_empty
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Class Methods
  # ---------------------------------------------------------------------------
  describe '.create_for_notification!' do
    it 'creates a log for email-channel notifications' do
      with_tenant(organisation) do
        log = nil
        expect do
          log = described_class.create_for_notification!(notification)
        end.to change(described_class, :count).by(1)

        expect(log.status).to eq('queued')
        expect(log.organisation).to eq(organisation)
        expect(log.notification).to eq(notification)
        expect(log.metadata).to include('to' => user.email)
      end
    end

    it 'returns nil for non-email notifications' do
      with_tenant(organisation) do
        in_app_notification = create(:notification,
                                     recipient: user,
                                     organisation: organisation,
                                     channel: 'in_app')

        result = described_class.create_for_notification!(in_app_notification)
        expect(result).to be_nil
      end
    end

    it 'populates metadata with subject and template' do
      with_tenant(organisation) do
        log = described_class.create_for_notification!(notification)

        expect(log.metadata).to have_key('subject')
        expect(log.metadata).to have_key('template')
        expect(log.metadata['sent_at']).to be_nil
      end
    end

    it 'allows overriding initial_status' do
      with_tenant(organisation) do
        log = described_class.create_for_notification!(notification, initial_status: :sent)
        expect(log.status).to eq('sent')
      end
    end

    context 'derive_subject_from_notification' do
      it 'maps ticket_assigned to "Ticket assigned"' do
        with_tenant(organisation) do
          assigned_notification = create(:notification, :ticket_assigned,
                                         recipient: user, organisation: organisation, channel: 'email')
          log = described_class.create_for_notification!(assigned_notification)
          expect(log.metadata['subject']).to eq('Ticket assigned')
        end
      end

      it 'maps ticket_commented to "New comment"' do
        with_tenant(organisation) do
          commented_notification = create(:notification, :ticket_commented,
                                          recipient: user, organisation: organisation, channel: 'email')
          log = described_class.create_for_notification!(commented_notification)
          expect(log.metadata['subject']).to eq('New comment')
        end
      end

      it 'humanizes unknown event types' do
        with_tenant(organisation) do
          system_notification = create(:notification,
                                       recipient: user, organisation: organisation,
                                       channel: 'email', event_type: 'system_message')
          log = described_class.create_for_notification!(system_notification)
          expect(log.metadata['subject']).to eq('System message')
        end
      end
    end

    context 'derive_template' do
      it 'appends _grouped for grouped notifications' do
        with_tenant(organisation) do
          grouped_notification = create(:notification,
                                        recipient: user, organisation: organisation, channel: 'email',
                                        group_count: 3, last_event_at: 10.minutes.ago)
          log = described_class.create_for_notification!(grouped_notification)
          expect(log.metadata['template']).to end_with('_grouped')
        end
      end

      it 'uses event_type as template for non-grouped notifications' do
        with_tenant(organisation) do
          log = described_class.create_for_notification!(notification)
          expect(log.metadata['template']).to eq(notification.event_type.to_s)
        end
      end
    end
  end

  describe '.record_delivery!' do
    it 'updates status to delivered and merges metadata' do
      with_tenant(organisation) do
        log = create_log(:sent, provider_message_id: 'msg_delivery_1')

        described_class.record_delivery!('msg_delivery_1', { delivery_time: 1.5 })

        log.reload
        expect(log.status).to eq('delivered')
        expect(log.metadata['delivered_at']).to be_present
        expect(log.metadata['delivery_time']).to eq(1.5)
      end
    end

    it 'does nothing for unknown message_id' do
      with_tenant(organisation) do
        expect do
          described_class.record_delivery!('nonexistent_id')
        end.not_to change(described_class, :count)
      end
    end

    it 'works with empty delivery_data' do
      with_tenant(organisation) do
        log = create_log(:sent, provider_message_id: 'msg_delivery_2')

        described_class.record_delivery!('msg_delivery_2')

        log.reload
        expect(log.status).to eq('delivered')
        expect(log.metadata['delivered_at']).to be_present
      end
    end
  end

  describe '.record_open!' do
    it 'updates status to opened and merges metadata' do
      with_tenant(organisation) do
        log = create_log(:delivered, provider_message_id: 'msg_open_1')

        described_class.record_open!('msg_open_1', { ip: '1.2.3.4', user_agent: 'TestBrowser' })

        log.reload
        expect(log.status).to eq('opened')
        expect(log.metadata['opened_at']).to be_present
        expect(log.metadata['ip_address']).to eq('1.2.3.4')
        expect(log.metadata['user_agent']).to eq('TestBrowser')
      end
    end

    it 'does not downgrade from clicked to opened' do
      with_tenant(organisation) do
        log = create_log(:clicked, provider_message_id: 'msg_open_2')

        described_class.record_open!('msg_open_2')

        expect(log.reload.status).to eq('clicked')
      end
    end

    it 'does nothing for unknown message_id' do
      expect do
        with_tenant(organisation) do
          described_class.record_open!('nonexistent_id')
        end
      end.not_to raise_error
    end

    it 'works with empty open_data' do
      with_tenant(organisation) do
        log = create_log(:delivered, provider_message_id: 'msg_open_3')

        described_class.record_open!('msg_open_3')

        log.reload
        expect(log.status).to eq('opened')
      end
    end
  end

  describe '.record_click!' do
    it 'updates status to clicked and appends click data' do
      with_tenant(organisation) do
        log = create_log(:opened, provider_message_id: 'msg_click_1')

        described_class.record_click!('msg_click_1', {
                                        url: 'https://example.com/link',
                                        ip: '5.6.7.8',
                                        user_agent: 'ClickBot'
                                      })

        log.reload
        expect(log.status).to eq('clicked')
        clicks = log.metadata['clicks']
        expect(clicks).to be_an(Array)
        expect(clicks.size).to eq(1)
        expect(clicks.first['url']).to eq('https://example.com/link')
        expect(clicks.first['clicked_at']).to be_present
      end
    end

    it 'appends multiple clicks to the array' do
      with_tenant(organisation) do
        log = create_log(:opened, provider_message_id: 'msg_click_2')

        described_class.record_click!('msg_click_2', { url: '/first' })
        described_class.record_click!('msg_click_2', { url: '/second' })

        log.reload
        clicks = log.metadata['clicks']
        expect(clicks.size).to eq(2)
        expect(clicks.map { |c| c['url'] }).to eq(['/first', '/second'])
      end
    end

    it 'initializes clicks array if none existed' do
      with_tenant(organisation) do
        log = create_log(:opened, provider_message_id: 'msg_click_3', metadata: {})

        described_class.record_click!('msg_click_3', { url: '/new' })

        log.reload
        expect(log.metadata['clicks']).to be_an(Array)
        expect(log.metadata['clicks'].size).to eq(1)
      end
    end

    it 'does nothing for unknown message_id' do
      expect do
        with_tenant(organisation) do
          described_class.record_click!('nonexistent_id', { url: '/x' })
        end
      end.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Instance Methods
  # ---------------------------------------------------------------------------
  describe '#successful?' do
    it 'returns true for sent' do
      expect(build_log(status: :sent).successful?).to be true
    end

    it 'returns true for opened' do
      expect(build_log(status: :opened).successful?).to be true
    end

    it 'returns true for clicked' do
      expect(build_log(status: :clicked).successful?).to be true
    end

    # BUG: successful? does NOT include :delivered, but the successful scope does.
    # The scope includes [:sent, :delivered, :opened, :clicked].
    # The instance method only checks status_sent? || status_opened? || status_clicked?.
    it 'returns false for delivered (inconsistent with .successful scope)' do
      expect(build_log(status: :delivered).successful?).to be false
    end

    it 'returns false for bounced' do
      expect(build_log(status: :bounced).successful?).to be false
    end

    it 'returns false for queued' do
      expect(build_log(status: :queued).successful?).to be false
    end
  end

  describe '#failed?' do
    it 'returns true for bounced' do
      expect(build_log(status: :bounced).failed?).to be true
    end

    it 'returns true for complaint' do
      expect(build_log(status: :complaint).failed?).to be true
    end

    it 'returns true for failed' do
      expect(build_log(status: :failed).failed?).to be true
    end

    it 'returns false for deferred' do
      expect(build_log(status: :deferred).failed?).to be false
    end

    it 'returns false for sent' do
      expect(build_log(status: :sent).failed?).to be false
    end
  end

  describe '#engagement?' do
    it 'returns true for opened' do
      expect(build_log(status: :opened).engagement?).to be true
    end

    it 'returns true for clicked' do
      expect(build_log(status: :clicked).engagement?).to be true
    end

    it 'returns false for delivered' do
      expect(build_log(status: :delivered).engagement?).to be false
    end

    it 'returns false for sent' do
      expect(build_log(status: :sent).engagement?).to be false
    end
  end

  describe '#engagement_time' do
    it 'returns seconds between sent_at and opened_at in metadata' do
      log = build_log(metadata: {
                        'sent_at' => '2026-01-01T10:00:00Z',
                        'opened_at' => '2026-01-01T10:05:00Z'
                      })

      expect(log.engagement_time).to eq(300.0) # 5 minutes
    end

    it 'returns nil when opened_at is missing' do
      log = build_log(metadata: { 'sent_at' => '2026-01-01T10:00:00Z' })
      expect(log.engagement_time).to be_nil
    end

    it 'returns nil when sent_at is missing' do
      log = build_log(metadata: { 'opened_at' => '2026-01-01T10:05:00Z' })
      expect(log.engagement_time).to be_nil
    end

    it 'returns nil when both timestamps are missing' do
      log = build_log(metadata: {})
      expect(log.engagement_time).to be_nil
    end

    # BUG: Time.parse without rescue can raise ArgumentError on invalid strings
    it 'raises ArgumentError for malformed timestamp strings' do
      log = build_log(metadata: {
                        'sent_at' => 'not-a-date',
                        'opened_at' => '2026-01-01T10:00:00Z'
                      })

      expect { log.engagement_time }.to raise_error(ArgumentError)
    end
  end

  describe '#delivery_time' do
    it 'returns seconds between sent_at and delivered_at' do
      log = build_log(sent_at: 10.minutes.ago, delivered_at: 5.minutes.ago)
      expect(log.delivery_time).to be_within(1).of(300.0)
    end

    it 'returns nil when sent_at is missing' do
      log = build_log(sent_at: nil, delivered_at: Time.current)
      expect(log.delivery_time).to be_nil
    end

    it 'returns nil when delivered_at is missing' do
      log = build_log(sent_at: Time.current, delivered_at: nil)
      expect(log.delivery_time).to be_nil
    end

    it 'returns nil when both are missing' do
      log = build_log(sent_at: nil, delivered_at: nil)
      expect(log.delivery_time).to be_nil
    end
  end

  describe '#open_rate' do
    # NOTE: This method only returns 0 or 100. It does not calculate a real rate.
    it 'returns 100 when open_count > 0' do
      log = build_log(open_count: 5)
      expect(log.open_rate).to eq(100.0)
    end

    it 'returns 0 when open_count is 0' do
      log = build_log(open_count: 0)
      expect(log.open_rate).to eq(0)
    end

    it 'returns 0 when open_count is nil' do
      log = build_log
      log.open_count = nil
      expect(log.open_rate).to eq(0)
    end
  end

  describe '#click_rate' do
    it 'calculates percentage of clicks relative to opens' do
      log = build_log(click_count: 3, open_count: 10)
      expect(log.click_rate).to eq(30.0)
    end

    it 'returns 0 when click_count is 0' do
      log = build_log(click_count: 0, open_count: 5)
      expect(log.click_rate).to eq(0)
    end

    it 'returns 0 when open_count is 0' do
      log = build_log(click_count: 3, open_count: 0)
      expect(log.click_rate).to eq(0)
    end

    it 'returns 0 when both are nil' do
      log = build_log
      log.click_count = nil
      log.open_count = nil
      expect(log.click_rate).to eq(0)
    end

    it 'handles click_count > open_count (returns > 100)' do
      log = build_log(click_count: 5, open_count: 2)
      expect(log.click_rate).to eq(250.0)
    end
  end

  # ---------------------------------------------------------------------------
  # body_html accessors
  # ---------------------------------------------------------------------------
  describe '#body_html / #body_html=' do
    it 'compresses and decompresses HTML round-trip' do
      log = build_log
      html = '<html><body><h1>Hello</h1><p>World</p></body></html>'
      log.body_html = html

      expect(log.body_html_compressed).to be_present
      expect(log.body_html).to eq(html)
    end

    it 'extracts preview text from HTML' do
      log = build_log
      log.body_html = '<html><body><h1>Title</h1><p>Some body text here</p></body></html>'

      expect(log.body_preview).to include('Title')
      expect(log.body_preview).to include('Some body text here')
    end

    it 'strips HTML tags from preview' do
      log = build_log
      log.body_html = '<p>Clean <strong>text</strong></p>'

      expect(log.body_preview).not_to include('<p>')
      expect(log.body_preview).not_to include('<strong>')
      expect(log.body_preview).to include('Clean')
      expect(log.body_preview).to include('text')
    end

    it 'truncates preview to 500 characters' do
      log = build_log
      log.body_html = "<p>#{'X' * 1000}</p>"

      expect(log.body_preview.length).to be <= 500
    end

    it 'does nothing when html is nil' do
      log = build_log
      log.body_html = nil

      expect(log.body_html_compressed).to be_nil
    end

    it 'does nothing when html is empty string' do
      log = build_log
      log.body_html = ''

      expect(log.body_html_compressed).to be_nil
    end

    it 'truncates HTML exceeding MAX_DECOMPRESSED_SIZE before compression' do
      log = build_log
      huge_html = 'X' * (EmailLog::MAX_DECOMPRESSED_SIZE + 1000)
      log.body_html = huge_html

      expect(log.body_html_compressed).to be_present
      # The stored content should be truncated
      decompressed = log.body_html
      expect(decompressed.bytesize).to be <= EmailLog::MAX_DECOMPRESSED_SIZE
    end

    it 'returns nil for body_html when no compressed data stored' do
      log = build_log
      expect(log.body_html).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # can_resend?
  # ---------------------------------------------------------------------------
  describe '#can_resend?' do
    it 'returns true for failed status with can_retry and low retry_count' do
      log = build_log(status: :failed, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be true
    end

    it 'returns true for bounced status' do
      log = build_log(status: :bounced, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be true
    end

    it 'returns true for deferred status' do
      log = build_log(status: :deferred, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be true
    end

    it 'returns false when can_retry is false' do
      log = build_log(status: :failed, can_retry: false, retry_count: 0)
      expect(log.can_resend?).to be false
    end

    it 'returns false when retry_count >= 3' do
      log = build_log(status: :failed, can_retry: true, retry_count: 3)
      expect(log.can_resend?).to be false
    end

    it 'returns false for sent status' do
      log = build_log(status: :sent, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be false
    end

    it 'returns false for delivered status' do
      log = build_log(status: :delivered, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be false
    end

    it 'returns false for queued status' do
      log = build_log(status: :queued, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be false
    end

    it 'returns false for opened status' do
      log = build_log(status: :opened, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be false
    end

    it 'returns false for complaint status' do
      log = build_log(status: :complaint, can_retry: true, retry_count: 0)
      expect(log.can_resend?).to be false
    end

    it 'returns true at retry_count 2 (below threshold)' do
      log = build_log(status: :failed, can_retry: true, retry_count: 2)
      expect(log.can_resend?).to be true
    end

    it 'handles nil retry_count' do
      log = build_log(status: :failed, can_retry: true)
      log.retry_count = nil
      # nil >= 3 is false in Ruby, so nil retry_count allows resend
      expect(log.can_resend?).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # resend!
  # ---------------------------------------------------------------------------
  describe '#resend!' do
    it 'creates a new queued log linked to original' do
      with_tenant(organisation) do
        original = create_log(status: :failed, can_retry: true, retry_count: 0,
                              recipient_email: 'test@example.com', subject: 'Original')

        new_log = original.resend!

        expect(new_log).to be_a(described_class)
        expect(new_log.status).to eq('queued')
        expect(new_log.resent_from_id).to eq(original.id)
        expect(new_log.recipient_email).to eq('test@example.com')
        expect(new_log.subject).to eq('Original')
        expect(new_log.metadata['original_id']).to eq(original.id)
        expect(new_log.metadata['resent_at']).to be_present
        expect(new_log.metadata['retry_attempt']).to eq(1)
      end
    end

    it 'increments retry_count on original' do
      with_tenant(organisation) do
        original = create_log(status: :failed, can_retry: true, retry_count: 0)

        original.resend!

        expect(original.reload.retry_count).to eq(1)
      end
    end

    it 'returns false when can_resend? is false' do
      with_tenant(organisation) do
        log = create_log(status: :sent, can_retry: true) # sent cannot be resent

        expect(log.resend!).to be false
      end
    end

    it 'returns false when retry_count is already at max' do
      with_tenant(organisation) do
        log = create_log(status: :failed, can_retry: true, retry_count: 3)

        expect(log.resend!).to be false
      end
    end

    it 'prevents duplicate resend within 1 minute' do
      with_tenant(organisation) do
        original = create_log(status: :failed, can_retry: true, retry_count: 0)

        first_resend = original.resend!
        expect(first_resend).to be_present

        # Second resend within 1 minute should be blocked
        result = original.reload.resend!
        expect(result).to be false
      end
    end

    it 'falls back to metadata for recipient_email and subject' do
      with_tenant(organisation) do
        original = create_log(status: :failed, can_retry: true, retry_count: 0,
                              recipient_email: nil, subject: nil,
                              metadata: { 'to' => 'fallback@example.com', 'subject' => 'Fallback Subject' })

        new_log = original.resend!

        expect(new_log.recipient_email).to eq('fallback@example.com')
        expect(new_log.subject).to eq('Fallback Subject')
      end
    end

    it 'enqueues EmailDeliveryJob after transaction' do
      with_tenant(organisation) do
        original = create_log(status: :failed, can_retry: true, retry_count: 0)

        expect(EmailDeliveryJob).to receive(:perform_later).with(notification.id)

        original.resend!
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks: handle_status_change
  # ---------------------------------------------------------------------------
  describe 'handle_status_change callback' do
    context 'when status changes to opened' do
      it 'calls mark_as_delivered! on the notification if state is sent' do
        with_tenant(organisation) do
          notification.update!(state: :sent, sent_at: 1.hour.ago)
          log = create_log(status: :sent)

          log.update!(status: :opened)

          expect(notification.reload.state).to eq('delivered')
        end
      end

      it 'does not call mark_as_delivered! if notification is already delivered' do
        with_tenant(organisation) do
          notification.update!(state: :delivered, delivered_at: 1.hour.ago)
          log = create_log(status: :sent)

          expect { log.update!(status: :opened) }.not_to(change { notification.reload.state })
        end
      end
    end

    context 'when status changes to clicked' do
      it 'calls mark_as_delivered! on the notification if state is sent' do
        with_tenant(organisation) do
          notification.update!(state: :sent, sent_at: 1.hour.ago)
          log = create_log(status: :opened)

          log.update!(status: :clicked)

          expect(notification.reload.state).to eq('delivered')
        end
      end
    end

    context 'when status changes to bounced' do
      it 'triggers check_and_disable_notifications' do
        with_tenant(organisation) do
          log = create_log(status: :sent)

          expect_any_instance_of(described_class).to receive(:check_and_disable_notifications)

          log.update!(status: :bounced)
        end
      end
    end

    context 'when status changes to complaint' do
      it 'triggers check_and_disable_notifications' do
        with_tenant(organisation) do
          log = create_log(status: :sent)

          expect_any_instance_of(described_class).to receive(:check_and_disable_notifications)

          log.update!(status: :complaint)
        end
      end
    end

    context 'when status does not change' do
      it 'does not trigger the callback' do
        with_tenant(organisation) do
          log = create_log(status: :sent)

          expect(log).not_to receive(:handle_status_change)

          log.update!(recipient_email: 'changed@example.com')
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases
  # ---------------------------------------------------------------------------
  describe 'edge cases' do
    describe '.record_bounce! with nil message_id' do
      it 'does nothing' do
        with_tenant(organisation) do
          expect do
            described_class.record_bounce!(nil, { type: 'Permanent', reason: 'test' })
          end.not_to raise_error
        end
      end
    end

    describe '.record_delivery! with nil message_id' do
      it 'does nothing' do
        with_tenant(organisation) do
          expect do
            described_class.record_delivery!(nil)
          end.not_to raise_error
        end
      end
    end

    describe '.record_open! with nil message_id' do
      it 'does nothing' do
        with_tenant(organisation) do
          expect do
            described_class.record_open!(nil)
          end.not_to raise_error
        end
      end
    end

    describe '.record_click! with nil message_id' do
      it 'does nothing' do
        with_tenant(organisation) do
          expect do
            described_class.record_click!(nil, { url: '/x' })
          end.not_to raise_error
        end
      end
    end

    describe 'metadata defaults' do
      it 'defaults to empty hash' do
        log = build_log(metadata: {})
        expect(log.metadata).to eq({})
      end

      it 'preserves existing metadata when merging in record_* methods' do
        with_tenant(organisation) do
          log = create_log(:sent,
                           provider_message_id: 'msg_preserve',
                           metadata: { 'custom_key' => 'custom_value' })

          described_class.record_delivery!('msg_preserve', { delivery_time: 2.0 })

          log.reload
          expect(log.metadata['custom_key']).to eq('custom_value')
          expect(log.metadata['delivered_at']).to be_present
        end
      end
    end

    describe 'lock_version for optimistic locking' do
      it 'starts at 0' do
        with_tenant(organisation) do
          log = create_log
          expect(log.lock_version).to eq(0)
        end
      end
    end
  end
end

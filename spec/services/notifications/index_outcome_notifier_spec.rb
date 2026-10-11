# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::IndexOutcomeNotifier do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:connector)    { create(:user, active: true) }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', connected_by_user: connector)
    end
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    repository            # force-create (+ its initial ProjectIndexerJob enqueue)
    clear_enqueued_jobs   # so the indexing enqueue can't pollute job assertions
    # Don't push over the cable in unit tests.
    allow(Notifications::BroadcastService).to receive(:new)
      .and_return(instance_double(Notifications::BroadcastService, broadcast_creation: nil))
  end
  after { ActsAsTenant.current_tenant = nil }

  def notifications_for(event_type)
    Notification.where(recipient: connector, event_type: event_type)
  end

  describe '.call — completed (default preferences = on)' do
    it 'creates exactly one in_app and one email notification for the connector' do
      expect { described_class.call(repository: repository, outcome: :completed) }
        .to change { notifications_for('index_completed').count }.by(2)
      expect(notifications_for('index_completed').pluck(:channel)).to contain_exactly('in_app', 'email')
    end

    it 'sets notifiable=repo, project, normal priority and a PII/secret-free payload' do
      described_class.call(repository: repository, outcome: :completed)
      n = notifications_for('index_completed').find_by(channel: 'in_app')
      expect(n).to have_attributes(notifiable: repository, project: project, priority: 'normal')
      expect(n.payload).to include('full_name' => 'acme/backend', 'repository_id' => repository.id, 'outcome' => 'completed')
      expect(n.payload.to_json).not_to include(repository.access_token)
    end

    it 'enqueues EmailDeliveryJob for the email notification' do
      expect { described_class.call(repository: repository, outcome: :completed) }
        .to have_enqueued_job(EmailDeliveryJob)
    end

    it 'broadcasts the in_app notification live' do
      broadcaster = instance_double(Notifications::BroadcastService, broadcast_creation: nil)
      allow(Notifications::BroadcastService).to receive(:new).and_return(broadcaster)
      described_class.call(repository: repository, outcome: :completed)
      expect(broadcaster).to have_received(:broadcast_creation)
    end
  end

  describe '.call — failed' do
    it 'uses event_type index_failed at high priority' do
      described_class.call(repository: repository, outcome: :failed)
      n = notifications_for('index_failed').find_by(channel: 'in_app')
      expect(n).to be_present
      expect(n.priority).to eq('high')
    end
  end

  describe 'configurability (respects NotificationPreference)' do
    it 'skips the email channel (notification + job) when the user disabled email' do
      NotificationPreference.create!(user: connector, event_type: 'index_completed',
                                     channel: 'email', frequency: 'never', enabled: false)

      expect { described_class.call(repository: repository, outcome: :completed) }
        .not_to have_enqueued_job(EmailDeliveryJob)
      expect(notifications_for('index_completed').where(channel: 'email')).to be_empty
      # in_app stays on (default), so the user still sees it in the center
      expect(notifications_for('index_completed').where(channel: 'in_app')).to exist
    end

    it 'skips the in_app channel when the user disabled it' do
      NotificationPreference.create!(user: connector, event_type: 'index_completed',
                                     channel: 'in_app', frequency: 'never', enabled: false)
      described_class.call(repository: repository, outcome: :completed)
      expect(notifications_for('index_completed').where(channel: 'in_app')).to be_empty
    end
  end

  describe 'guards' do
    it 'does nothing (no crash) when there is no connector' do
      repository.update!(connected_by_user: nil)
      expect { described_class.call(repository: repository, outcome: :completed) }
        .not_to change(Notification, :count)
    end

    it 'does nothing for an inactive connector' do
      connector.update!(active: false)
      expect { described_class.call(repository: repository, outcome: :completed) }
        .not_to change(Notification, :count)
    end
  end

  describe 'idempotency' do
    it 'does not duplicate when called twice for the same index outcome' do
      repository.project_index.update!(status: 'ready', last_indexed_at: Time.current) # stable discriminator
      described_class.call(repository: repository, outcome: :completed)
      expect { described_class.call(repository: repository, outcome: :completed) }
        .not_to change(Notification, :count)
    end

    # The failed discriminator uses a DIFFERENT stamp (index.updated_at) than the
    # completed one — guard its idempotency separately.
    it 'does not duplicate when called twice for the same failure' do
      described_class.call(repository: repository, outcome: :failed)
      expect { described_class.call(repository: repository, outcome: :failed) }
        .not_to change(Notification, :count)
    end
  end

  describe 'best-effort (never breaks the indexing job)' do
    it 'swallows an unexpected persistence failure instead of raising' do
      allow(Notification).to receive(:create!).and_raise(StandardError, 'db down')
      expect { described_class.call(repository: repository, outcome: :completed) }.not_to raise_error
    end

    # A duplicate (RecordNotUnique) is normal idempotency — it must be swallowed
    # by its OWN rescue (no error log), distinct from an unexpected failure.
    it 'treats a RecordNotUnique as a clean no-op, not a logged error' do
      allow(Notification).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
      expect(Rails.logger).not_to receive(:error)
      expect { described_class.call(repository: repository, outcome: :completed) }.not_to raise_error
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Lifecycle contract of a GDPR export request (doc/user_data_export_plan.md §2):
# the 24h throttle must never lock a user out because of an infrastructure
# failure (failed exports do not count), and expiry drives both download
# availability and cleanup.
RSpec.describe UserDataExport, type: :model do
  let(:user) { create(:user) }

  describe 'request throttle (24h, on create)' do
    it 'allows the first export' do
      expect(build(:user_data_export, user: user)).to be_valid
    end

    it 'rejects a second request within 24h of a completed export' do
      create(:user_data_export, :completed, user: user, created_at: 2.hours.ago)

      export = build(:user_data_export, user: user)
      expect(export).not_to be_valid
      expect(export.errors.details[:base]).to include(error: :too_frequent)
    end

    it 'rejects a second request while one is still pending' do
      create(:user_data_export, user: user, created_at: 1.minute.ago)

      expect(build(:user_data_export, user: user)).not_to be_valid
    end

    it 'allows a new request once 24h have passed' do
      create(:user_data_export, :completed, user: user, created_at: 25.hours.ago)

      expect(build(:user_data_export, user: user)).to be_valid
    end

    # Boundary pair around REQUEST_INTERVAL: kills both an interval change
    # (24h → 23h) and an operator flip (<= → <) in request_interval_respected.
    it 'still rejects just inside the 24h boundary' do
      create(:user_data_export, :completed, user: user,
                                            created_at: UserDataExport::REQUEST_INTERVAL.ago + 1.minute)

      expect(build(:user_data_export, user: user)).not_to be_valid
    end

    it 'allows just outside the 24h boundary' do
      create(:user_data_export, :completed, user: user,
                                            created_at: UserDataExport::REQUEST_INTERVAL.ago - 1.second)

      expect(build(:user_data_export, user: user)).to be_valid
    end

    it 'does NOT throttle after a failed export (Art. 15 must not be blocked by our failure)' do
      create(:user_data_export, :failed, user: user, created_at: 1.minute.ago)

      expect(build(:user_data_export, user: user)).to be_valid
    end

    it 'throttles per user, not globally' do
      create(:user_data_export, user: create(:user), created_at: 1.minute.ago)

      expect(build(:user_data_export, user: user)).to be_valid
    end
  end

  describe 'DB race guard (partial unique index, D5)' do
    it 'refuses a second ACTIVE export at the database layer even if validation is bypassed' do
      create(:user_data_export, user: user)
      racer = build(:user_data_export, user: user)

      expect { racer.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'permits a new active export once the previous one is failed' do
      create(:user_data_export, :failed, user: user)
      racer = build(:user_data_export, user: user)

      expect { racer.save(validate: false) }.not_to raise_error
    end
  end

  describe 'column defaults as contract (not set via factory)' do
    it 'defaults status to pending on a bare insert' do
      export = UserDataExport.create!(user: user)
      expect(export.reload.status).to eq('pending')
    end
  end

  describe '#downloadable? / #expired?' do
    it 'is downloadable while completed, attached and unexpired' do
      export = create(:user_data_export, :completed, user: user)
      expect(export).to be_downloadable
      expect(export).not_to be_expired
    end

    # Boundary right at expiry: a just-passed expires_at must flip BOTH
    # predicates — this is what gates the download redirect.
    it 'flips to expired the moment expires_at is past' do
      export = create(:user_data_export, :completed, user: user)
      export.update!(expires_at: 1.second.ago)

      expect(export).not_to be_downloadable
      expect(export).to be_expired
    end

    it 'is expired (and not downloadable) past expires_at' do
      export = create(:user_data_export, :expired, user: user)
      expect(export).not_to be_downloadable
      expect(export).to be_expired
    end

    it 'is not downloadable while pending' do
      expect(create(:user_data_export, user: user)).not_to be_downloadable
    end
  end

  describe 'scopes' do
    it 'finds expired and stale rows for the cleanup job' do
      expired = create(:user_data_export, :expired, user: user)
      stale = create(:user_data_export, :failed, user: create(:user), created_at: 31.days.ago)
      fresh = create(:user_data_export, user: create(:user))

      expect(described_class.expired).to contain_exactly(expired)
      expect(described_class.stale).to contain_exactly(stale)
      expect(described_class.active).to contain_exactly(fresh)
    end

    # Boundary: a 29-day-old row must survive the cleanup — kills a
    # ROW_RETENTION change (30 → 7 days) that would eat rows early.
    it 'does not treat rows younger than ROW_RETENTION as stale' do
      create(:user_data_export, :failed, user: user, created_at: 29.days.ago)

      expect(described_class.stale).to be_empty
    end
  end

  describe 'deletion layers (defense in depth)' do
    before { ActiveJob::Base.queue_adapter = :test }

    # Layer 1: Rails-level dependent: :destroy — fires on a hard #destroy and
    # takes the attachment purge with it. Kills a removed `dependent:` option.
    # Hard-destroying a User is only possible INSIDE a tenant: other dependent
    # associations (posts, subscriptions, …) are acts_as_tenant and their
    # destroy callbacks raise NoTenantSet otherwise — mirrors console reality.
    it 'destroys exports (incl. blob purge) when the user is hard-destroyed' do
      export = create(:user_data_export, :completed, user: user)

      ActsAsTenant.with_tenant(create(:organisation)) do
        expect { user.destroy! }
          .to change { UserDataExport.exists?(export.id) }.from(true).to(false)
          .and have_enqueued_job(ActiveStorage::PurgeJob)
      end
    end

    # Layer 2: DB-level ON DELETE CASCADE — holds even when Rails callbacks
    # are bypassed entirely (raw DELETE). Kills a dropped FK cascade option
    # in the migration.
    it 'cascades rows at the DB layer on a raw user delete' do
      export = create(:user_data_export, user: user)

      user.delete

      expect(UserDataExport.exists?(export.id)).to be(false)
    end
  end
end

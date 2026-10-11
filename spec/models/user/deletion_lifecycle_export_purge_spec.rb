# frozen_string_literal: true

require 'rails_helper'

# REGRESSION GUARD (eng review D3, critical): the account erasure path is a
# soft-delete — no hard DELETE ever runs on users, so the FK CASCADE on
# user_data_exports NEVER fires. Without the explicit purge in
# PersonalDataErasure#erase_data_exports! (reached from soft_delete_and_anonymize!
# on both paths), a full plain-text PII archive (name, email, login IPs) would
# survive an Art.-17 erasure for up to 7 days. This file guards the ::User path in
# depth; the cross-path guard is spec/models/user_erasure_path_parity_spec.rb.
RSpec.describe User::DeletionLifecycle, type: :model do
  describe '#soft_delete_and_anonymize! purges data exports' do
    let(:user) { create(:user) }

    before { ActiveJob::Base.queue_adapter = :test }

    it 'destroys the export rows' do
      # Old failed export FIRST — it does not count towards the throttle, so
      # the completed one afterwards passes the 24h validation.
      create(:user_data_export, :failed, user: user, created_at: 2.days.ago)
      create(:user_data_export, :completed, user: user)

      expect { user.soft_delete_and_anonymize! }
        .to change { UserDataExport.where(user_id: user.id).count }.from(2).to(0)
    end

    it 'enqueues the archive blob purge (after commit, never inside the transaction)' do
      create(:user_data_export, :completed, user: user)

      expect { user.soft_delete_and_anonymize! }
        .to have_enqueued_job(ActiveStorage::PurgeJob)
    end

    it 'still anonymizes the user row itself' do
      create(:user_data_export, :completed, user: user)
      user.soft_delete_and_anonymize!

      expect(user.reload.email).to match(/anonym_\w+@deleted\.local/)
      expect(user.deleted_at).to be_present
    end
  end
end

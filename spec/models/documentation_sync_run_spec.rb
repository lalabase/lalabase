# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_sync_runs
#
#  id                   :uuid             not null, primary key
#  commit_sha           :string
#  error_class          :string
#  error_message        :text
#  finished_at          :datetime
#  pages_removed        :integer          default(0), not null
#  pages_synced         :integer          default(0), not null
#  started_at           :datetime
#  status               :string           not null
#  trigger              :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#  triggered_by_user_id :uuid
#
# Indexes
#
#  idx_on_documentation_set_id_created_at_714010eb45      (documentation_set_id,created_at)
#  index_documentation_sync_runs_on_documentation_set_id  (documentation_set_id)
#  index_documentation_sync_runs_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (triggered_by_user_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

# What: DocumentationSyncRun — status/trigger/error_class validations and
#       duration helper.
# Type: Model spec.
# Why:  Each run is the audit record a user reads to know why a sync failed;
#       the six-class error taxonomy (DT4) must be enforced as a contract.
RSpec.describe DocumentationSyncRun, type: :model do
  let(:organisation) { create(:organisation) }
  let(:set) { create(:documentation_set, project: create(:project, organisation: organisation)) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'validations' do
    it 'is valid with the factory' do
      expect(build(:documentation_sync_run, documentation_set: set)).to be_valid
    end

    it 'requires a known status' do
      expect(build(:documentation_sync_run, documentation_set: set, status: 'bogus')).not_to be_valid
    end

    it 'requires a known trigger' do
      expect(build(:documentation_sync_run, documentation_set: set, trigger: 'bogus')).not_to be_valid
    end

    it 'allows a nil error_class (success)' do
      expect(build(:documentation_sync_run, documentation_set: set, error_class: nil)).to be_valid
    end

    it 'rejects an unknown error_class' do
      expect(build(:documentation_sync_run, documentation_set: set, error_class: 'kaboom')).not_to be_valid
    end

    # Defense-in-depth: every taxonomy class the sync job may set must persist.
    it 'accepts each of the six taxonomy error classes' do
      DocumentationSyncRun::ERROR_CLASSES.each do |klass|
        run = build(:documentation_sync_run, documentation_set: set, status: 'failed', error_class: klass)
        expect(run).to be_valid, "expected error_class #{klass.inspect} to be valid"
      end
    end
  end

  # Positive iteration: dropping a status/trigger value must break a test.
  describe 'status + trigger whitelists' do
    DocumentationSyncRun::STATUSES.each do |status|
      it "accepts status #{status.inspect}" do
        expect(build(:documentation_sync_run, documentation_set: set, status: status)).to be_valid
      end
    end

    DocumentationSyncRun::TRIGGERS.each do |trigger|
      it "accepts trigger #{trigger.inspect}" do
        expect(build(:documentation_sync_run, documentation_set: set, trigger: trigger)).to be_valid
      end
    end
  end

  # Migration defaults are a contract; set via create! (NOT the factory).
  describe 'insert-level defaults' do
    it 'defaults the page counters to 0 when omitted on insert' do
      run = DocumentationSyncRun.create!(organisation: organisation, documentation_set: set,
                                         status: 'ready', trigger: 'manual')
      expect(run.reload).to have_attributes(pages_synced: 0, pages_removed: 0)
    end
  end

  # FK on_delete: :nullify — a run outlives the user who triggered it.
  describe 'triggered_by_user hard-delete' do
    it 'nullifies triggered_by_user_id instead of deleting the run' do
      user = create(:user)
      run = create(:documentation_sync_run, documentation_set: set, triggered_by_user: user)

      user.delete # raw DELETE → exercises the FK on_delete rule

      expect(run.reload.triggered_by_user_id).to be_nil
    end
  end

  describe '#duration_seconds' do
    it 'returns the elapsed seconds' do
      run = build(:documentation_sync_run, started_at: Time.current, finished_at: Time.current + 5)
      expect(run.duration_seconds).to eq(5)
    end

    it 'is zero when start and finish coincide (0-boundary)' do
      now = Time.current
      run = build(:documentation_sync_run, started_at: now, finished_at: now)
      expect(run.duration_seconds).to eq(0)
    end

    it 'is nil when unfinished' do
      run = build(:documentation_sync_run, started_at: Time.current, finished_at: nil)
      expect(run.duration_seconds).to be_nil
    end
  end
end

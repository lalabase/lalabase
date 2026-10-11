# frozen_string_literal: true

# == Schema Information
#
# Table name: project_index_runs
#
#  id                    :uuid             not null, primary key
#  commit_sha            :string
#  error_message         :text
#  files_count           :integer          default(0), not null
#  finished_at           :datetime         not null
#  incremental           :boolean          default(FALSE), not null
#  started_at            :datetime         not null
#  status                :string           not null
#  symbols_added         :integer          default(0), not null
#  symbols_removed       :integer          default(0), not null
#  trigger               :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#  triggered_by_user_id  :uuid
#
# Indexes
#
#  idx_on_project_repository_id_created_at_faef1120bf  (project_repository_id,created_at)
#  index_project_index_runs_on_organisation_id         (organisation_id)
#  index_project_index_runs_on_triggered_by_user_id    (triggered_by_user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#  fk_rails_...  (triggered_by_user_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

RSpec.describe ProjectIndexRun, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository) do
    create(:project_repository, project: project, organisation: organisation, full_name: 'acme/x')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def build_run(**attrs)
    build(:project_index_run, project_repository: repository, organisation: organisation, **attrs)
  end

  describe 'validations' do
    it 'is valid with the factory defaults' do
      expect(build_run).to be_valid
    end

    # Positive iteration over the whitelist: if someone shrinks TRIGGERS/STATUSES,
    # exactly the removed value goes red here.
    described_class::TRIGGERS.each do |value|
      it "accepts trigger #{value.inspect}" do
        expect(build_run(trigger: value)).to be_valid
      end
    end

    it 'rejects an unknown trigger' do
      run = build_run(trigger: 'nope')
      expect(run).not_to be_valid
      expect(run.errors[:trigger]).to be_present
    end

    # Exact-match: a case-insensitive or whitespace-trimming mutation of the
    # inclusion validation would otherwise let these slip through.
    it 'rejects a trigger differing only in case ("INITIAL")' do
      expect(build_run(trigger: 'INITIAL')).not_to be_valid
    end

    it 'rejects a trigger with surrounding whitespace ("initial ")' do
      expect(build_run(trigger: 'initial ')).not_to be_valid
    end

    described_class::STATUSES.each do |value|
      it "accepts status #{value.inspect}" do
        expect(build_run(status: value)).to be_valid
      end
    end

    it 'rejects an unknown status' do
      expect(build_run(status: 'maybe')).not_to be_valid
    end

    it 'requires started_at and finished_at' do
      expect(build_run(started_at: nil)).not_to be_valid
      expect(build_run(finished_at: nil)).not_to be_valid
    end

    # Iterate over ALL three guarded columns + the zero boundary. The old single
    # symbols_added test let two mutations survive: dropping files_count or
    # symbols_removed from the numericality validation, and `>= 0` → `> 0`.
    %i[files_count symbols_added symbols_removed].each do |col|
      it "rejects a negative #{col}" do
        run = build_run(col => -1)
        expect(run).not_to be_valid
        expect(run.errors[col]).to be_present
      end

      it "accepts #{col} == 0 (zero boundary)" do
        expect(build_run(col => 0)).to be_valid
      end
    end
  end

  describe 'DB-level NOT NULL (defense in depth)' do
    # The model validates presence; the column is ALSO null: false. Bypassing the
    # model (validate: false) must still hit the DB constraint — catches a
    # migration that drops null: false once someone deems the model rule redundant.
    it 'raises NotNullViolation on a nil trigger when the model validation is bypassed' do
      run = build_run(trigger: nil)
      expect { run.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'cascade delete (dependent: :destroy on ProjectRepository)' do
    # Catches removal of `has_many :project_index_runs, dependent: :destroy` — the
    # history must not outlive its repository (and a bare FK would block the delete).
    it 'is destroyed together with its project_repository' do
      run = create(:project_index_run, project_repository: repository, organisation: organisation)
      expect { repository.destroy! }
        .to change { described_class.where(id: run.id).count }.from(1).to(0)
    end
  end

  # Opposite policy to the repository: a deleted TRIGGERER must NOT take the history
  # with it (column nullable + belongs_to optional). Tested on BOTH layers because
  # either one alone masks a regression of the other (defense in depth, category 1).
  describe 'triggered_by_user: history survives a deleted triggerer (nullify, not RESTRICT/destroy)' do
    let!(:triggerer) { create(:user) }
    let!(:run) do
      create(:project_index_run, project_repository: repository,
                                 organisation: organisation, triggered_by_user: triggerer)
    end

    # Model layer: User#destroy runs `dependent: :nullify` before the DELETE.
    # Catches a regression to `dependent: :destroy` (the run would vanish) or a
    # removed association (the user delete would then raise on the FK).
    it 'keeps the run and nils the triggerer when the user is destroyed (model layer)' do
      expect { triggerer.destroy! }.not_to(change { described_class.where(id: run.id).count })
      expect(run.reload.triggered_by_user_id).to be_nil
    end

    # DB layer: #delete bypasses the model callback, so only the FK on_delete:
    # :nullify can save us here. Catches a regression of the FK back to RESTRICT —
    # which would raise ActiveRecord::InvalidForeignKey instead.
    it 'nils the triggerer even when the model callback is bypassed (FK on_delete)' do
      expect { triggerer.delete }.not_to raise_error
      expect(run.reload.triggered_by_user_id).to be_nil
    end
  end

  describe 'defaults on insert (contract — NOT set via factory)' do
    it 'defaults counts to 0 and incremental to false when omitted' do
      run = described_class.create!(
        organisation: organisation, project_repository: repository,
        trigger: 'initial', status: 'ready',
        started_at: 1.second.ago, finished_at: Time.current
      )
      expect(run.reload).to have_attributes(
        files_count: 0, symbols_added: 0, symbols_removed: 0, incremental: false
      )
    end
  end

  describe '#duration_seconds' do
    it 'is the whole-second gap between started_at and finished_at' do
      run = build_run(started_at: Time.utc(2026, 5, 30, 12, 0, 0),
                      finished_at: Time.utc(2026, 5, 30, 12, 0, 9))
      expect(run.duration_seconds).to eq(9)
    end

    # build (not create) — the presence validation would otherwise block a nil
    # timestamp; we want to exercise the method's own nil-guard (the View calls
    # `if run.duration_seconds`, so a removed guard would raise live).
    it 'returns nil when a timestamp is missing (guards against nil arithmetic)' do
      expect(build_run(finished_at: nil).duration_seconds).to be_nil
    end
  end

  describe '.recent' do
    it 'orders newest first' do
      older = create(:project_index_run, project_repository: repository,
                                         organisation: organisation, created_at: 2.hours.ago)
      newer = create(:project_index_run, project_repository: repository,
                                         organisation: organisation, created_at: 1.minute.ago)
      expect(described_class.recent.to_a).to eq([newer, older])
    end
  end

  describe 'tenant isolation' do
    it 'only returns runs of the current tenant' do
      mine = create(:project_index_run, project_repository: repository, organisation: organisation)

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_repo = create(:project_repository,
                            project: create(:project, organisation: other_org),
                            organisation: other_org, full_name: 'other/repo')
        create(:project_index_run, project_repository: other_repo, organisation: other_org)
      end

      expect(described_class.all).to contain_exactly(mine)
    end
  end
end

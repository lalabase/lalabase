# frozen_string_literal: true

# == Schema Information
#
# Table name: dashboard_configurations
#
#  id              :uuid             not null, primary key
#  layout          :jsonb            not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  project_id      :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  idx_dashboard_config_project_default               (project_id) UNIQUE WHERE (user_id IS NULL)
#  idx_dashboard_config_user_project                  (user_id,project_id) UNIQUE
#  index_dashboard_configurations_on_organisation_id  (organisation_id)
#  index_dashboard_configurations_on_project_id       (project_id)
#  index_dashboard_configurations_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

# What:  DashboardConfiguration — persistence + layout validation for the auto-columns dashboard.
# Type:  Model specs (DB-backed; errors.details asserted so validation checks are locale-independent).
# Why:   A layout is rows of widgets; each widget has a width in 1/6-of-a-row units. The validation
#        contract is now: a row is a Hash with a `widgets` Array (NO row "type" anymore), Σ widget
#        units must fit ROW_UNITS, and a per-widget `units` (when present) must be an integer within
#        [registry minimum, ROW_UNITS]. Uniqueness + DB constraints are unchanged.
RSpec.describe DashboardConfiguration, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'associations' do
    it { should belong_to(:project) }
    it { should belong_to(:user).optional }
  end

  describe 'multi-tenancy' do
    it 'scopes queries to current tenant' do
      config = create(:dashboard_configuration, user: user, project: project, organisation: organisation)

      other_org = create(:organisation)
      other_project = create(:project, organisation: other_org)
      ActsAsTenant.with_tenant(other_org) do
        create(:dashboard_configuration, user: user, project: other_project, organisation: other_org)
      end

      expect(DashboardConfiguration.all).to contain_exactly(config)
    end
  end

  describe 'validations' do
    describe 'user_id uniqueness per project' do
      it 'allows one config per user+project' do
        create(:dashboard_configuration, user: user, project: project, organisation: organisation)
        duplicate = build(:dashboard_configuration, user: user, project: project, organisation: organisation)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it 'allows same user in different projects' do
        project2 = create(:project, organisation: organisation)
        create(:dashboard_configuration, user: user, project: project, organisation: organisation)
        config2 = build(:dashboard_configuration, user: user, project: project2, organisation: organisation)
        expect(config2).to be_valid
      end

      it 'allows different users in same project' do
        user2 = create(:user)
        create(:dashboard_configuration, user: user, project: project, organisation: organisation)
        config2 = build(:dashboard_configuration, user: user2, project: project, organisation: organisation)
        expect(config2).to be_valid
      end
    end

    describe 'project default uniqueness' do
      it 'allows one project-default per project' do
        create(:dashboard_configuration, :project_default, project: project, organisation: organisation)
        duplicate = build(:dashboard_configuration, :project_default, project: project, organisation: organisation)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it 'allows project-defaults across different projects' do
        project2 = create(:project, organisation: organisation)
        create(:dashboard_configuration, :project_default, project: project, organisation: organisation)
        config2 = build(:dashboard_configuration, :project_default, project: project2, organisation: organisation)
        expect(config2).to be_valid
      end

      it 'allows updating an existing project-default without uniqueness conflict' do
        config = create(:dashboard_configuration, :project_default, project: project, organisation: organisation)
        config.layout = [{ 'widgets' => ['stats_cards'] }]
        expect(config).to be_valid
      end

      it 'allows user configs alongside a project-default' do
        create(:dashboard_configuration, :project_default, project: project, organisation: organisation)
        user_config = build(:dashboard_configuration, user: user, project: project, organisation: organisation)
        expect(user_config).to be_valid
      end
    end

    # errors.details is asserted (not the message string) so checks are locale-independent and pin
    # the exact rule that fired.
    describe 'layout structure validation' do
      def build_config(layout:)
        build(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: layout)
      end

      def layout_errors(config)
        config.valid?
        config.errors.details[:layout].map { |d| d[:error] }
      end

      context 'with a blank layout' do
        it 'is valid for nil (blank skips structure validation)' do
          expect(build_config(layout: nil)).to be_valid
        end

        it 'is valid for an empty array' do
          expect(build_config(layout: [])).to be_valid
        end
      end

      context 'with a non-array layout' do
        it 'rejects a string, a hash and an integer' do
          ['invalid', { 'widgets' => [] }, 42].each do |bad|
            expect(layout_errors(build_config(layout: bad))).to include(:not_an_array)
          end
        end
      end

      context 'with valid rows' do
        it 'accepts a single-widget row (no row "type" required)' do
          expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'stats_cards' }] }])).to be_valid
        end

        it 'accepts two widgets that fit the track' do
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }]
          expect(build_config(layout: layout)).to be_valid
        end

        it 'accepts an empty widgets array' do
          expect(build_config(layout: [{ 'widgets' => [] }])).to be_valid
        end

        it 'accepts a row that still carries a legacy "type" key (ignored)' do
          expect(build_config(layout: [{ 'type' => 'full', 'widgets' => ['stats_cards'] }])).to be_valid
        end
      end

      context 'with an invalid row shape' do
        it 'rejects a row without a widgets key' do
          expect(layout_errors(build_config(layout: [{ 'foo' => 'bar' }]))).to include(:row_missing_widgets)
        end

        it 'rejects a row whose widgets is not an array' do
          expect(layout_errors(build_config(layout: [{ 'widgets' => 'nope' }]))).to include(:row_missing_widgets)
        end

        it 'rejects a non-hash row element and a nil row element' do
          expect(layout_errors(build_config(layout: ['invalid_row']))).to include(:row_missing_widgets)
          expect(layout_errors(build_config(layout: [nil]))).to include(:row_missing_widgets)
        end
      end

      context 'with widget format validation' do
        it 'accepts legacy string widgets and hash widgets with a key' do
          expect(build_config(layout: [{ 'widgets' => ['stats_cards'] }])).to be_valid
          expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'stats_cards' }] }])).to be_valid
        end

        it 'accepts blank, nil and empty-string widget entries' do
          expect(build_config(layout: [{ 'widgets' => [nil, ''] }])).to be_valid
        end

        it 'rejects a hash widget without a key' do
          expect(layout_errors(build_config(layout: [{ 'widgets' => [{ 'folder_id' => 'abc' }] }]))).to include(:widget_invalid_format)
        end

        it 'rejects a hash widget with a blank key' do
          expect(layout_errors(build_config(layout: [{ 'widgets' => [{ 'key' => '' }] }]))).to include(:widget_invalid_format)
        end

        it 'rejects numeric and array widget entries' do
          expect(layout_errors(build_config(layout: [{ 'widgets' => [123] }]))).to include(:widget_invalid_format)
          expect(layout_errors(build_config(layout: [{ 'widgets' => [%w[nested]] }]))).to include(:widget_invalid_format)
        end
      end

      context 'with multiple rows (mixed valid/invalid)' do
        it 'collects errors from several invalid rows' do
          layout = [
            { 'widgets' => [{ 'key' => 'stats_cards' }] }, # valid
            { 'foo' => 'bar' },                             # row_missing_widgets
            { 'widgets' => [{ 'key' => '' }] }              # widget_invalid_format
          ]
          expect(layout_errors(build_config(layout: layout))).to include(:row_missing_widgets, :widget_invalid_format)
        end
      end
    end

    # The width constraint: Σ widget units must fit the 6-unit track, and a per-widget `units` (when
    # present) must be an integer within [registry minimum, ROW_UNITS].
    describe 'units validation' do
      def build_config(layout:)
        build(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: layout)
      end

      def layout_errors(config)
        config.valid?
        config.errors.details[:layout].map { |d| d[:error] }
      end

      context 'row units sum' do
        it 'accepts a row whose widths fit ROW_UNITS' do
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 4 }, { 'key' => 'recent_notes' }] }] # 4 + 2 = 6
          expect(build_config(layout: layout)).to be_valid
        end

        it 'rejects a row whose widths sum beyond ROW_UNITS' do
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 4 }, { 'key' => 'recent_notes', 'units' => 4 }] }] # 8 > 6
          expect(layout_errors(build_config(layout: layout))).to include(:row_units_exceeds)
        end

        it 'counts a width-less widget as its minimum toward the sum' do
          # stats(min1) + project_info(min2) + recent_tickets(min2) + recent_notes(min2) = 7 > 6
          layout = [{ 'widgets' => [{ 'key' => 'stats_cards' }, { 'key' => 'project_info' },
                                    { 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }]
          expect(layout_errors(build_config(layout: layout))).to include(:row_units_exceeds)
        end

        it 'does not count blank entries toward the sum' do
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 4 }, nil, ''] }] # 4 <= 6
          expect(build_config(layout: layout)).to be_valid
        end
      end

      context 'per-widget units' do
        it 'accepts an absent units key (defaults to the minimum)' do
          expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'recent_tickets' }] }])).to be_valid
        end

        it 'accepts a units value within [minimum, ROW_UNITS]' do
          expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 2 }] }])).to be_valid
          expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 6 }] }])).to be_valid
        end

        it 'rejects a units value below the registry minimum' do
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 1 }] }] # min is 2
          expect(layout_errors(build_config(layout: layout))).to include(:widget_units_invalid)
        end

        it 'rejects a units value above ROW_UNITS' do
          layout = [{ 'widgets' => [{ 'key' => 'stats_cards', 'units' => 7 }] }]
          expect(layout_errors(build_config(layout: layout))).to include(:widget_units_invalid)
        end

        it 'rejects a non-integer units value' do
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => '2' }] }]
          expect(layout_errors(build_config(layout: layout))).to include(:widget_units_invalid)
        end

        it 'treats an unknown widget key as minimum 1 (its key is not range-checked here)' do
          expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'totally_unknown', 'units' => 3 }] }])).to be_valid
        end
      end
    end

    context 'item limit' do
      def build_config(layout:)
        build(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: layout)
      end

      def layout_errors(config)
        config.valid?
        config.errors.details[:layout].map { |d| d[:error] }
      end

      it 'accepts a whitelisted limit on a list widget' do
        layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'limit' => 15 }] }]
        expect(build_config(layout: layout)).to be_valid
      end

      it 'accepts a layout with no limit key (backward compatible)' do
        expect(build_config(layout: [{ 'widgets' => [{ 'key' => 'recent_notes' }] }])).to be_valid
      end

      it 'rejects a limit outside the whitelist' do
        layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'limit' => 7 }] }]
        expect(layout_errors(build_config(layout: layout))).to include(:widget_limit_invalid)
      end

      it 'rejects a non-integer limit (forged string value)' do
        layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'limit' => '15' }] }]
        expect(layout_errors(build_config(layout: layout))).to include(:widget_limit_invalid)
      end

      it 'accepts every whitelisted option (positive iteration over the constant)' do
        Dashboards::LayoutEngine::LIST_LIMIT_OPTIONS.each do |n|
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'limit' => n }] }]
          expect(layout_errors(build_config(layout: layout))).not_to include(:widget_limit_invalid), "limit #{n} should be valid"
        end
      end

      it 'accepts the boundary options 5 and 25 but rejects 4 and 26' do
        { 5 => false, 25 => false, 4 => true, 26 => true }.each do |limit, should_fail|
          layout = [{ 'widgets' => [{ 'key' => 'recent_tickets', 'limit' => limit }] }]
          fired = layout_errors(build_config(layout: layout)).include?(:widget_limit_invalid)
          expect(fired).to eq(should_fail), "limit #{limit}: expected invalid=#{should_fail}"
        end
      end

      # Key-AGNOSTIC by design: only list widgets render the control, but a forged limit on ANY widget
      # (e.g. a hand-crafted stats_cards JSONB that bypasses the editor) must be rejected, not kept.
      it 'rejects a forged limit on a non-list widget yet accepts a whitelisted one' do
        bad = [{ 'widgets' => [{ 'key' => 'stats_cards', 'limit' => 7 }] }]
        expect(layout_errors(build_config(layout: bad))).to include(:widget_limit_invalid)

        good = [{ 'widgets' => [{ 'key' => 'stats_cards', 'limit' => 15 }] }]
        expect(layout_errors(build_config(layout: good))).not_to include(:widget_limit_invalid)
      end
    end
  end

  describe '.for_user_project' do
    it 'returns existing config when found' do
      existing = create(:dashboard_configuration, user: user, project: project, organisation: organisation)
      result = DashboardConfiguration.for_user_project(user, project)
      expect(result).to eq(existing)
      expect(result).to be_persisted
    end

    it 'initializes new config with system default layout' do
      result = DashboardConfiguration.for_user_project(user, project)
      expect(result).to be_new_record
      expect(result.layout).to eq(Dashboards::LayoutEngine::SYSTEM_DEFAULT_LAYOUT)
      expect(result.user).to eq(user)
      expect(result.project).to eq(project)
    end

    it 'does not return config of another user' do
      other_user = create(:user)
      create(:dashboard_configuration, user: other_user, project: project, organisation: organisation)

      expect(DashboardConfiguration.for_user_project(user, project)).to be_new_record
    end

    it 'does not return config of another project' do
      other_project = create(:project, organisation: organisation)
      create(:dashboard_configuration, user: user, project: other_project, organisation: organisation)

      expect(DashboardConfiguration.for_user_project(user, project)).to be_new_record
    end

    it 'initializes a saveable record' do
      result = DashboardConfiguration.for_user_project(user, project)
      expect(result.save).to be true
      expect(result).to be_persisted
    end
  end

  # Defense in depth: the model validations and the DB indexes/constraints are SEPARATE layers.
  # These bypass the model (save!(validate: false)) so that removing a model validation as
  # "redundant" — or making a partial index non-partial, or dropping the layout default/NOT NULL —
  # cannot pass silently. This also pins the RecordNotUnique surface behind the concurrent
  # default-save race noted in review.
  describe 'DB-level constraints (defense in depth)' do
    it 'enforces user+project uniqueness at the DB even when the model validation is bypassed' do
      create(:dashboard_configuration, user: user, project: project, organisation: organisation)
      dup = build(:dashboard_configuration, user: user, project: project, organisation: organisation)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'enforces project-default uniqueness (partial index) at the DB when the model validation is bypassed' do
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation)
      dup = build(:dashboard_configuration, :project_default, project: project, organisation: organisation)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'lets a user-config and a project-default for the SAME project coexist (partial WHERE user_id IS NULL)' do
      # If someone drops the "WHERE user_id IS NULL" and makes the project_id index plain-unique,
      # this user-config would collide with the project-default and raise — so this pins the partial.
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation)
      user_cfg = build(:dashboard_configuration, user: user, project: project, organisation: organisation)
      expect { user_cfg.save!(validate: false) }.not_to raise_error
    end

    it 'applies the [] layout DB default when the column is omitted on insert' do
      # NOT via the factory (which sets layout) — insert without it so the DB default is what is tested.
      record = described_class.create!(organisation: organisation, project: project, user: user)
      expect(record.reload.layout).to eq([])
    end

    it 'rejects an explicit nil layout at the DB (NOT NULL), though the model treats nil as blank/valid' do
      record = build(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: nil)
      expect(record).to be_valid # model: nil is blank -> structure validation is skipped
      expect { record.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What:  Actors::SaveDashboardLayout — the single write path behind the project-dashboard editor.
# Type:  Service spec (actor contract: scope dispatch, one shared transaction, failure Result).
# Why:   One form, four save targets (scope kwarg). Pinned here: every scope writes exactly its
#        target rows; saving a default clears ONLY the acting user's own personal overrides; ALL
#        scopes share one transaction (a late failure rolls back earlier rows — the controller
#        version lacked this for default_this); on failure #record returns a rebuilt, re-validated
#        config of the CURRENT context carrying the rejected layout (the 422 frame re-render, A2).
RSpec.describe Actors::SaveDashboardLayout, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  # Tenant must be set BEFORE the let! hooks below create tenant-scoped records.
  before { ActsAsTenant.current_tenant = organisation }

  let!(:project_a) { create(:project, organisation: organisation) }
  let!(:project_b) { create(:project, organisation: organisation) }

  let(:layout) { [{ 'widgets' => [{ 'key' => 'stats_cards' }] }] }
  # Over-full row: 4 + 4 units > ROW_UNITS (6) -> row_units_exceeds at validation time.
  let(:invalid_layout) do
    [{ 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 4 },
                     { 'key' => 'recent_notes', 'units' => 4 }] }]
  end

  # project_a is the "current" project of the request; projects mirrors the
  # policy-scoped relation the controller passes in (array keeps order deterministic).
  def call_actor(scope:, layout: self.layout, projects: [project_a, project_b])
    described_class.call(
      project: project_a, projects: projects, organisation: organisation,
      current_user: user, layout: layout, scope: scope
    )
  end

  def config_count
    ActsAsTenant.without_tenant { DashboardConfiguration.count }
  end

  describe "scope 'personal_this'" do
    it "writes the acting user's own row for the current project only" do
      result = call_actor(scope: 'personal_this')

      expect(result).to be_success
      config = DashboardConfiguration.find_by(user: user, project: project_a)
      expect(config).to be_present
      expect(config.layout).to eq(layout)
      expect(config.organisation).to eq(organisation)
      expect(DashboardConfiguration.find_by(user: user, project: project_b)).to be_nil
      expect(DashboardConfiguration.where(user: nil)).to be_empty
    end

    it 'updates an existing own row in place (no duplicate)' do
      existing = create(:dashboard_configuration, user: user, project: project_a, organisation: organisation,
                                                  layout: [{ 'widgets' => [{ 'key' => 'notifications' }] }])

      expect { call_actor(scope: 'personal_this') }.not_to(change { config_count })
      expect(existing.reload.layout).to eq(layout)
    end

    it 'returns the saved row as the result resource' do
      result = call_actor(scope: 'personal_this')

      expect(result.resource).to be_a(DashboardConfiguration)
      expect(result.resource).to be_persisted
      expect(result.resource.user).to eq(user)
      expect(result.resource.project).to eq(project_a)
    end
  end

  describe "scope 'default_this'" do
    it 'writes the shared project default (user_id NULL) for the current project only' do
      result = call_actor(scope: 'default_this')

      expect(result).to be_success
      expect(DashboardConfiguration.find_by(user: nil, project: project_a)).to be_present
      expect(DashboardConfiguration.find_by(user: nil, project: project_b)).to be_nil
    end

    it "clears ONLY the acting user's own override for that project" do
      own_a = create(:dashboard_configuration, user: user, project: project_a, organisation: organisation)
      own_b = create(:dashboard_configuration, user: user, project: project_b, organisation: organisation)
      foreign_a = create(:dashboard_configuration, user: other_user, project: project_a, organisation: organisation)

      call_actor(scope: 'default_this')

      expect(DashboardConfiguration.exists?(own_a.id)).to be(false)
      expect(DashboardConfiguration.exists?(own_b.id)).to be(true)
      expect(DashboardConfiguration.exists?(foreign_a.id)).to be(true)
    end

    it 'keeps the own override and writes no default when the layout is invalid' do
      own = create(:dashboard_configuration, user: user, project: project_a, organisation: organisation)

      result = call_actor(scope: 'default_this', layout: invalid_layout)

      expect(result).not_to be_success
      expect(DashboardConfiguration.exists?(own.id)).to be(true)
      expect(DashboardConfiguration.find_by(user: nil, project: project_a)).to be_nil
    end
  end

  describe "scope 'personal_all'" do
    it "writes the acting user's own row for every given project, never a default row" do
      # Per-project upsert loop -> repeated query shapes are intentional, not an N+1
      # (same pause as in the request specs).
      Prosopite.pause
      result = call_actor(scope: 'personal_all')

      expect(result).to be_success
      [project_a, project_b].each do |project|
        config = DashboardConfiguration.find_by(user: user, project: project)
        expect(config).to be_present
        expect(config.layout).to eq(layout)
      end
      expect(DashboardConfiguration.where(user: nil)).to be_empty
    ensure
      Prosopite.resume
    end

    it 'updates existing own rows in place (no duplicates)' do
      create(:dashboard_configuration, user: user, project: project_b, organisation: organisation,
                                       layout: [{ 'widgets' => [{ 'key' => 'notifications' }] }])

      expect { call_actor(scope: 'personal_all') }.to change { config_count }.by(1) # a new, b updated

      expect(DashboardConfiguration.where(user: user, project: project_b).count).to eq(1)
      expect(DashboardConfiguration.find_by(user: user, project: project_b).layout).to eq(layout)
    end
  end

  describe "scope 'default_all'" do
    it 'writes a default row per given project and clears only the own overrides' do
      own_a = create(:dashboard_configuration, user: user, project: project_a, organisation: organisation)
      foreign_b = create(:dashboard_configuration, user: other_user, project: project_b, organisation: organisation)

      # Per-project upsert loop -> repeated query shapes are intentional, not an N+1
      # (same pause as in the request specs).
      Prosopite.pause
      result = call_actor(scope: 'default_all')

      expect(result).to be_success
      expect(result.resource).to be_persisted
      expect(result.resource.user).to be_nil
      expect(result.resource.project).to eq(project_a)
      [project_a, project_b].each do |project|
        expect(DashboardConfiguration.find_by(user: nil, project: project)).to be_present
      end
      expect(DashboardConfiguration.exists?(own_a.id)).to be(false)
      expect(DashboardConfiguration.exists?(foreign_b.id)).to be(true)
    ensure
      Prosopite.resume
    end

    it 'updates an existing default row in place (no duplicate)' do
      create(:dashboard_configuration, :project_default, project: project_b, organisation: organisation,
                                                         layout: [{ 'widgets' => [{ 'key' => 'notifications' }] }])

      expect { call_actor(scope: 'default_all') }.to change { config_count }.by(1) # a new, b updated

      expect(DashboardConfiguration.find_by(user: nil, project: project_b).layout).to eq(layout)
    end

    # The transaction proof (D4): the first project's row IS written, then the second save fails —
    # the shared transaction must roll the first write back. Stubbing save! is the only way to make
    # one specific later save fail (the layout validation is project-independent by design).
    it 'persists nothing when a later project save fails (rollback proof)' do
      saves = 0
      allow_any_instance_of(DashboardConfiguration).to receive(:save!).and_wrap_original do |original, *args|
        saves += 1
        raise ActiveRecord::RecordInvalid, original.receiver if saves == 2

        original.call(*args)
      end

      result = call_actor(scope: 'default_all')

      expect(result).not_to be_success
      expect(saves).to be >= 2 # the first save really ran before the failure
      expect(config_count).to eq(0)
    end
  end

  describe 'failure contract (A2 frame re-render)' do
    it 'maps a validation failure to a :validation_failed Result' do
      result = call_actor(scope: 'personal_this', layout: invalid_layout)

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(result.errors).to be_present
      expect(config_count).to eq(0)
    end

    it 'returns a rebuilt, re-validated config of the current context carrying the rejected layout' do
      result = call_actor(scope: 'default_all', layout: invalid_layout)

      config = result.resource
      expect(config).to be_a(DashboardConfiguration)
      expect(config).not_to be_persisted
      expect(config.user).to eq(user)
      expect(config.project).to eq(project_a)
      expect(config.layout).to eq(invalid_layout)
      expect(config.errors[:layout]).to be_present # re-validated, ready for the 422 frame
    end

    it 'restores the previous Current.user even on failure' do
      Current.user = nil
      call_actor(scope: 'personal_this', layout: invalid_layout)

      expect(Current.user).to be_nil
    end
  end

  describe 'RecordNotUnique mapping (parallel first-time default save)' do
    it 'maps the unique-index race to a :conflict failure instead of a 500' do
      racy = DashboardConfiguration.new(user: nil, project: project_a, organisation: organisation)
      allow(racy).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, 'duplicate key')
      allow(DashboardConfiguration).to receive(:find_or_initialize_by).and_call_original
      allow(DashboardConfiguration).to receive(:find_or_initialize_by)
        .with(user: nil, project: project_a).and_return(racy)

      result = call_actor(scope: 'default_this')

      expect(result).not_to be_success
      expect(result.code).to eq(:conflict)
      expect(result.errors).to include(
        I18n.t('activerecord.errors.models.dashboard_configuration.attributes.user_id.project_default_exists')
      )
    end
  end

  describe 'unknown scope' do
    it 'raises (a scope outside the controller whitelist is a programming error)' do
      expect { call_actor(scope: 'bogus') }.to raise_error(ArgumentError, /bogus/)
    end
  end
end

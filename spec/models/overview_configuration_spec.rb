# frozen_string_literal: true

require 'rails_helper'

# What:  OverviewConfiguration — persistence + layout validation for the configurable organisation
#        overview (briefings#show). Org-scoped sibling of DashboardConfiguration (no project).
# Type:  Model specs (DB-backed; errors.details asserted so checks are locale-independent).
# Why:   The overview reuses the SHARED layout engine + the SHARED Dashboards::ConfigValidations
#        concern, but bound to its OWN widget set (Overview::WidgetRegistry). These specs pin two
#        things the sharing must get right: (1) the cascade scope is the ORGANISATION (one org
#        default per org, one personal config per user+org, tenant-isolated); (2) the layout
#        validation evaluates units/limits against the OVERVIEW registry, not the project one.
RSpec.describe OverviewConfiguration, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Locale-independent: assert the error SYMBOLS, not the rendered message.
  def layout_errors(config)
    config.valid?
    config.errors.details[:layout].map { |d| d[:error] }
  end

  def build_config(layout:, **attrs)
    build(:overview_configuration, organisation: organisation, layout: layout, **attrs)
  end

  describe 'associations' do
    it { should belong_to(:user).optional }
  end

  describe 'multi-tenancy' do
    it 'scopes queries to the current tenant (no cross-org leak)' do
      mine = create(:overview_configuration, user: user, organisation: organisation)

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        create(:overview_configuration, user: user, organisation: other_org)
      end

      expect(OverviewConfiguration.all).to contain_exactly(mine)
    end
  end

  describe 'uniqueness' do
    describe 'personal config per user + organisation' do
      it 'forbids a second personal config for the same user+org' do
        create(:overview_configuration, user: user, organisation: organisation)
        duplicate = build(:overview_configuration, user: user, organisation: organisation)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it 'allows the same user to have a config in a different org' do
        create(:overview_configuration, user: user, organisation: organisation)
        other_org = create(:organisation)
        ActsAsTenant.with_tenant(other_org) do
          expect(build(:overview_configuration, user: user, organisation: other_org)).to be_valid
        end
      end
    end

    describe 'org default (user_id NULL)' do
      it 'forbids a second org default for the same organisation' do
        create(:overview_configuration, :org_default, organisation: organisation)
        duplicate = build(:overview_configuration, :org_default, organisation: organisation)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it 'allows an org default to coexist with a personal config in the same org' do
        create(:overview_configuration, :org_default, organisation: organisation)
        expect(build(:overview_configuration, user: user, organisation: organisation)).to be_valid
      end
    end
  end

  describe 'layout validation (against the OVERVIEW registry)' do
    it 'accepts the shipped system default layout' do
      expect(build_config(layout: Overview::WidgetRegistry::SYSTEM_DEFAULT_LAYOUT)).to be_valid
    end

    it 'accepts an empty layout (the cascade treats [] as "no preference")' do
      expect(build_config(layout: [])).to be_valid
    end

    it 'accepts a row whose widget units sum to exactly ROW_UNITS' do
      # projects_table (4) + my_week_stats (2) = 6
      layout = [{ 'widgets' => [{ 'key' => 'projects_table', 'units' => 4 },
                                { 'key' => 'my_week_stats', 'units' => 2 }] }]
      expect(layout_errors(build_config(layout: layout))).to be_empty
    end

    it 'rejects a row whose units exceed ROW_UNITS (overview minimums)' do
      # projects_table (min 4) + org_activity_feed (min 3) = 7 > 6, even without explicit units
      layout = [{ 'widgets' => [{ 'key' => 'projects_table' }, { 'key' => 'org_activity_feed' }] }]
      expect(layout_errors(build_config(layout: layout))).to include(:row_units_exceeds)
    end

    it 'rejects per-widget units below the overview registry minimum' do
      # my_week_stats minimum is 2; 1 is below it
      layout = [{ 'widgets' => [{ 'key' => 'my_week_stats', 'units' => 1 }] }]
      expect(layout_errors(build_config(layout: layout))).to include(:widget_units_invalid)
    end

    it 'rejects per-widget units above ROW_UNITS' do
      layout = [{ 'widgets' => [{ 'key' => 'unread_summary', 'units' => 10 }] }]
      expect(layout_errors(build_config(layout: layout))).to include(:widget_units_invalid)
    end

    it 'rejects a non-whitelisted per-widget item limit' do
      layout = [{ 'widgets' => [{ 'key' => 'org_activity_feed', 'limit' => 7 }] }]
      expect(layout_errors(build_config(layout: layout))).to include(:widget_limit_invalid)
    end

    it 'accepts a whitelisted per-widget item limit' do
      layout = [{ 'widgets' => [{ 'key' => 'org_activity_feed', 'limit' => 10 }] }]
      expect(layout_errors(build_config(layout: layout))).to be_empty
    end

    it 'rejects a layout that is not an array' do
      expect(layout_errors(build_config(layout: { 'widgets' => [] }))).to include(:not_an_array)
    end

    it 'rejects a row without a widgets array' do
      expect(layout_errors(build_config(layout: [{ 'foo' => 'bar' }]))).to include(:row_missing_widgets)
    end
  end

  describe '.for_user_organisation' do
    it 'initialises a new config seeded with the overview system default' do
      config = OverviewConfiguration.for_user_organisation(user, organisation)
      expect(config).to be_new_record
      expect(config.layout).to eq(Overview::WidgetRegistry::SYSTEM_DEFAULT_LAYOUT)
    end

    it 'returns the existing config for a user that already has one' do
      existing = create(:overview_configuration, user: user, organisation: organisation, layout: [])
      expect(OverviewConfiguration.for_user_organisation(user, organisation)).to eq(existing)
    end
  end
end

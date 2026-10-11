# frozen_string_literal: true

require 'rails_helper'

# What:  Actors::SaveOverviewLayout — the single write path behind the organisation-overview editor.
# Type:  Service spec (actor contract: scope dispatch, one shared transaction, failure Result).
# Why:   One form, two save targets (scope kwarg: personal / org default). Pinned here: each scope
#        writes exactly its target row; saving the default clears ONLY the acting user's own
#        override; save + override-clearing share one transaction (the controller version lacked
#        this); on failure #record returns a rebuilt, re-validated config of the CURRENT context
#        carrying the rejected layout (the 422 frame re-render, A2).
RSpec.describe Actors::SaveOverviewLayout, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  let(:layout) { [{ 'widgets' => [{ 'key' => 'org_activity_feed' }] }] }
  # Over-full row: 4 + 4 units > ROW_UNITS (6) -> row_units_exceeds at validation time.
  let(:invalid_layout) do
    [{ 'widgets' => [{ 'key' => 'org_activity_feed', 'units' => 4 },
                     { 'key' => 'projects_table', 'units' => 4 }] }]
  end

  def call_actor(scope:, layout: self.layout)
    described_class.call(
      organisation: organisation, current_user: user, layout: layout, scope: scope
    )
  end

  def config_count
    ActsAsTenant.without_tenant { OverviewConfiguration.count }
  end

  describe "scope 'personal'" do
    it "writes the acting user's own row, never the org default" do
      result = call_actor(scope: 'personal')

      expect(result).to be_success
      config = OverviewConfiguration.find_by(user: user, organisation: organisation)
      expect(config).to be_present
      expect(config.layout).to eq(layout)
      expect(OverviewConfiguration.find_by(user: nil, organisation: organisation)).to be_nil
    end

    it 'updates an existing own row in place (no duplicate)' do
      existing = create(:overview_configuration, user: user, organisation: organisation,
                                                 layout: [{ 'widgets' => [{ 'key' => 'projects_table' }] }])

      expect { call_actor(scope: 'personal') }.not_to(change { config_count })
      expect(existing.reload.layout).to eq(layout)
    end

    it 'returns the saved row as the result resource' do
      result = call_actor(scope: 'personal')

      expect(result.resource).to be_a(OverviewConfiguration)
      expect(result.resource).to be_persisted
      expect(result.resource.user).to eq(user)
    end
  end

  describe "scope 'default'" do
    it 'writes the shared org default (user_id NULL)' do
      result = call_actor(scope: 'default')

      expect(result).to be_success
      expect(result.resource).to be_persisted
      expect(result.resource.user).to be_nil
      config = OverviewConfiguration.find_by(user: nil, organisation: organisation)
      expect(config).to be_present
      expect(config.layout).to eq(layout)
    end

    it "clears ONLY the acting user's own override, keeping other members' configs" do
      own = create(:overview_configuration, user: user, organisation: organisation)
      foreign = create(:overview_configuration, user: other_user, organisation: organisation)

      call_actor(scope: 'default')

      expect(OverviewConfiguration.exists?(own.id)).to be(false)
      expect(OverviewConfiguration.exists?(foreign.id)).to be(true)
    end

    it 'keeps the own override and writes no default when the layout is invalid' do
      own = create(:overview_configuration, user: user, organisation: organisation)

      result = call_actor(scope: 'default', layout: invalid_layout)

      expect(result).not_to be_success
      expect(OverviewConfiguration.exists?(own.id)).to be(true)
      expect(OverviewConfiguration.find_by(user: nil, organisation: organisation)).to be_nil
    end

    # The transaction proof (D4): the controller version saved the default and THEN deleted the
    # own override without a transaction — a failing delete left the default committed but hidden
    # behind the stale override. The actor must roll the save back. Failing delete_all is only
    # reachable via stubbing; the raise propagates in test (unexpected-error policy re-raises).
    it 'rolls the default save back when clearing the own override fails (rollback proof)' do
      create(:overview_configuration, user: user, organisation: organisation)

      failing_relation = instance_double(ActiveRecord::Relation)
      allow(failing_relation).to receive(:delete_all).and_raise(ActiveRecord::StatementInvalid, 'boom')
      allow(OverviewConfiguration).to receive(:where).and_call_original
      allow(OverviewConfiguration).to receive(:where)
        .with(user: user, organisation: organisation).and_return(failing_relation)

      expect { call_actor(scope: 'default') }.to raise_error(ActiveRecord::StatementInvalid)
      expect(OverviewConfiguration.find_by(user: nil, organisation: organisation)).to be_nil
    end
  end

  describe 'failure contract (A2 frame re-render)' do
    it 'maps a validation failure to a :validation_failed Result and persists nothing' do
      result = call_actor(scope: 'personal', layout: invalid_layout)

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(result.errors).to be_present
      expect(config_count).to eq(0)
    end

    it 'returns a rebuilt, re-validated config of the current context carrying the rejected layout' do
      result = call_actor(scope: 'default', layout: invalid_layout)

      config = result.resource
      expect(config).to be_a(OverviewConfiguration)
      expect(config).not_to be_persisted
      expect(config.user).to eq(user)
      expect(config.layout).to eq(invalid_layout)
      expect(config.errors[:layout]).to be_present # re-validated, ready for the 422 frame
    end

    it 'restores the previous Current.user even on failure' do
      Current.user = nil
      call_actor(scope: 'personal', layout: invalid_layout)

      expect(Current.user).to be_nil
    end
  end

  describe 'RecordNotUnique mapping (parallel first-time default save)' do
    it 'maps the unique-index race to a :conflict failure instead of a 500' do
      racy = OverviewConfiguration.new(user: nil, organisation: organisation)
      allow(racy).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, 'duplicate key')
      allow(OverviewConfiguration).to receive(:find_or_initialize_by).and_call_original
      allow(OverviewConfiguration).to receive(:find_or_initialize_by)
        .with(user: nil, organisation: organisation).and_return(racy)

      result = call_actor(scope: 'default')

      expect(result).not_to be_success
      expect(result.code).to eq(:conflict)
      expect(result.errors).to include(
        I18n.t('activerecord.errors.models.overview_configuration.attributes.user_id.org_default_exists')
      )
    end
  end

  describe 'unknown scope' do
    it 'raises (a scope outside the controller whitelist is a programming error)' do
      expect { call_actor(scope: 'bogus') }.to raise_error(ArgumentError, /bogus/)
    end
  end
end

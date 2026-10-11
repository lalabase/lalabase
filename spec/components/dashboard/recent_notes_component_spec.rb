# frozen_string_literal: true

require 'rails_helper'

# What:  RecentNotesComponent item-count wiring.
# Why:   The shared limit math is unit-tested in dashboard_configurable_spec; here we prove THIS
#        component threads the `limit:` kwarg end to end — it reaches the reader (a dropped
#        `@limit = limit` in the initializer regresses #item_limit) AND the query is actually capped
#        (reverting `.limit(item_limit)` regresses #recent_notes). Tested on the private members so no
#        route helpers / render path are involved.
RSpec.describe Dashboard::RecentNotesComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe '#item_limit (kwarg wiring)' do
    it 'defaults to 5 when no limit is given' do
      expect(described_class.new(project: project, user: user).send(:item_limit)).to eq(5)
    end

    it 'uses a stored valid limit' do
      expect(described_class.new(project: project, user: user, limit: 15).send(:item_limit)).to eq(15)
    end

    it 'ignores an out-of-whitelist limit and falls back to the default' do
      expect(described_class.new(project: project, user: user, limit: 7).send(:item_limit)).to eq(5)
    end
  end

  describe '#recent_notes honours the limit in the query' do
    before do
      12.times { |i| create(:note, project: project, organisation: organisation, updated_at: i.minutes.ago) }
    end

    it 'caps at DEFAULT_ITEM_LIMIT (5) when no limit is configured' do
      expect(described_class.new(project: project, user: user).send(:recent_notes).to_a.size).to eq(5)
    end

    it 'returns exactly the configured number of rows' do
      expect(described_class.new(project: project, user: user, limit: 10).send(:recent_notes).to_a.size).to eq(10)
    end
  end
end

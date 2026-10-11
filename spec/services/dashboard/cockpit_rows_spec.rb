# frozen_string_literal: true

require 'rails_helper'

# Pure-Ruby view-model: driven with lightweight stand-ins for the two services so the unit test
# needs no DB, no tenant, and no request. It only asserts the merge/projection behaviour (one row
# per active org, action slice + to-dos joined by org id, quiet-org detection).
RSpec.describe Dashboard::CockpitRows do
  let(:org_a) { instance_double(Organisation, id: 'a', name: 'Alpha') }
  let(:org_b) { instance_double(Organisation, id: 'b', name: 'Beta') }
  let(:org_c) { instance_double(Organisation, id: 'c', name: 'Gamma') }

  def slice(actionable:, error: false)
    instance_double(Dashboard::CrossOrgActionSummary::OrgActionSlice,
                    error: error, actionable_count: actionable)
  end

  let(:slice_a) { slice(actionable: 2) }
  let(:slice_c) { slice(actionable: 0) }

  let(:action_summary) do
    instance_double(Dashboard::CrossOrgActionSummary,
                    slices_by_org: { 'a' => slice_a, 'c' => slice_c })
  end

  let(:rollup) do
    instance_double(Dashboard::PersonalTaskRollup, slices: [[org_b, %i[t1 t2]]])
  end

  subject(:view_model) do
    described_class.new(organisations: [org_a, org_b, org_c], action_summary: action_summary, rollup: rollup)
  end

  def rows_by_id
    view_model.rows.index_by { |row| row.organisation.id }
  end

  it 'builds one row per active org, in the given order' do
    expect(view_model.rows.map(&:organisation)).to eq([org_a, org_b, org_c])
  end

  it 'attaches the matching action slice and to-dos by org id' do
    expect(rows_by_id['a'].action_slice).to be(slice_a)
    expect(rows_by_id['b'].todos).to eq(%i[t1 t2])
  end

  it 'defaults to empty to-dos for an org with none' do
    expect(rows_by_id['a'].todos).to eq([])
  end

  it 'leaves action_slice nil for an org absent from slices_by_org (no crash)' do
    expect(rows_by_id['b'].action_slice).to be_nil
    expect(rows_by_id['b'].actions?).to be(false)
  end

  describe 'Row predicates' do
    it 'reports actions? from the slice actionable count' do
      expect(rows_by_id['a'].actions?).to be(true)   # actionable 2
      expect(rows_by_id['c'].actions?).to be(false)  # actionable 0
    end

    it 'never reports actions? for an error slice, but does report error?' do
      errored = described_class.new(organisations: [org_a],
                                    action_summary: instance_double(Dashboard::CrossOrgActionSummary,
                                                                    slices_by_org: { 'a' => slice(actionable: 5, error: true) }),
                                    rollup: instance_double(Dashboard::PersonalTaskRollup, slices: []))
      row = errored.rows.first
      expect(row.actions?).to be(false)
      expect(row.error?).to be(true)
    end

    it 'does not report error? for a healthy or quiet slice' do
      expect(rows_by_id['a'].error?).to be(false) # actionable
      expect(rows_by_id['c'].error?).to be(false) # quiet but not errored
    end
  end
end

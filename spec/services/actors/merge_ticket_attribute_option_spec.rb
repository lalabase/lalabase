# frozen_string_literal: true

# spec/services/actors/merge_ticket_attribute_option_spec.rb
#
# What: unit spec for the MergeTicketAttributeOption actor (moved out of the model's
#   deleted #merge_option!). Covers select + multiselect, the coded validation
#   failures, a mid-batch rollback, the F2 skip, and an F4 measurement of the audit
#   cost (one Activity/OutboxEvent per rewritten ticket).
# Why: the merge rewrites N tickets AND the definition in one transaction; the
#   contract is atomicity + an accurate updated_count for the flash.
#
# Prosopite note: the per-ticket write loop is an INTENTIONAL bulk op (F4 keeps the
# audit chain), not a request N+1 — so the merge/heavy-setup calls run inside
# Prosopite.pause. That does not hide the cost: the F4 example measures it explicitly.

require 'rails_helper'

RSpec.describe Actors::MergeTicketAttributeOption, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  let!(:status_attr) do
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                           { 'value' => 'in_progress', 'labels' => { 'de' => 'In Arbeit', 'en' => 'WIP' } },
                                           { 'value' => 'closed', 'labels' => { 'de' => 'Erledigt', 'en' => 'Closed' } }
                                         ] })
  end

  # Runs the merge with N+1 detection paused (intentional bulk write, see header).
  def run_merge(source:, target:, definition: status_attr)
    actor = described_class.new(attribute_definition: definition, source_value: source,
                                target_value: target, current_user: user)
    Prosopite.pause
    result = actor.call
    Prosopite.resume
    [result, actor]
  end

  def make_ticket(attrs)
    Prosopite.pause
    ticket = create(:ticket, project: project, creator: user, custom_attributes: attrs)
    Prosopite.resume
    ticket
  end

  describe 'select merge' do
    let!(:t1) { make_ticket('status' => 'open') }
    let!(:t2) { make_ticket('status' => 'open') }
    let!(:other) { make_ticket('status' => 'in_progress') }

    it 'moves every source-valued ticket to the target and counts them' do
      result, actor = run_merge(source: 'open', target: 'closed')

      expect(result).to be_success
      expect(actor.updated_count).to eq(2)
      expect(t1.reload.get_custom_attribute('status')).to eq('closed')
      expect(t2.reload.get_custom_attribute('status')).to eq('closed')
      expect(other.reload.get_custom_attribute('status')).to eq('in_progress') # untouched
    end

    it 'removes the source option from the definition' do
      run_merge(source: 'open', target: 'closed')
      expect(status_attr.reload.allowed_values.map { |v| v['value'] }).to contain_exactly('in_progress', 'closed')
    end

    it 'stamps updater on the rewritten tickets' do
      run_merge(source: 'open', target: 'closed')
      expect(t1.reload.updater).to eq(user)
    end

    it 'exposes the definition as the record' do
      _result, actor = run_merge(source: 'open', target: 'closed')
      expect(actor.record).to eq(status_attr)
    end
  end

  describe 'multiselect merge' do
    let!(:tags_attr) do
      create(:ticket_attribute_definition, project: project, name: 'tags', field_type: 'multiselect',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'a', 'labels' => { 'de' => 'A', 'en' => 'A' } },
                                             { 'value' => 'b', 'labels' => { 'de' => 'B', 'en' => 'B' } },
                                             { 'value' => 'c', 'labels' => { 'de' => 'C', 'en' => 'C' } }
                                           ] })
    end
    let!(:t1) { make_ticket('tags' => %w[a b]) }
    let!(:t2) { make_ticket('tags' => %w[c]) } # no source → not matched

    it 'merges the value inside the array and dedups' do
      result, actor = run_merge(source: 'a', target: 'b', definition: tags_attr)

      expect(result).to be_success
      expect(actor.updated_count).to eq(1)
      expect(t1.reload.get_custom_attribute('tags')).to contain_exactly('b') # [a,b] - a + b, uniq
      expect(t2.reload.get_custom_attribute('tags')).to eq(%w[c])
    end
  end

  describe 'validation failures (coded, no writes)' do
    let!(:t1) { make_ticket('status' => 'open') }

    it 'fails with :source_equals_target' do
      result, = run_merge(source: 'open', target: 'open')
      expect(result).not_to be_success
      expect(result.code).to eq(:source_equals_target)
      expect(t1.reload.get_custom_attribute('status')).to eq('open')
    end

    it 'fails with :source_not_found' do
      result, = run_merge(source: 'ghost', target: 'closed')
      expect(result.code).to eq(:source_not_found)
    end

    it 'fails with :target_not_found' do
      result, = run_merge(source: 'open', target: 'ghost')
      expect(result.code).to eq(:target_not_found)
    end

    it 'leaves the definition options intact on failure' do
      run_merge(source: 'open', target: 'ghost')
      expect(status_attr.reload.allowed_values.map { |v| v['value'] }).to include('open')
    end
  end

  describe 'rollback mid-batch' do
    let!(:t1) { make_ticket('status' => 'open') }
    let!(:t2) { make_ticket('status' => 'open') }

    it 'rolls back all ticket writes AND the option removal when one write fails' do
      calls = 0
      allow_any_instance_of(Ticket).to receive(:update!).and_wrap_original do |m, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid, m.receiver if calls == 2

        m.call(*args)
      end

      result, = run_merge(source: 'open', target: 'closed')

      expect(result).not_to be_success
      expect(t1.reload.get_custom_attribute('status')).to eq('open') # rolled back
      expect(t2.reload.get_custom_attribute('status')).to eq('open')
      expect(status_attr.reload.allowed_values.map { |v| v['value'] }).to include('open') # option NOT removed
    end
  end

  # F2: a legacy-invalid NEIGHBOUR attribute must not block the merge.
  describe 'legacy-invalid neighbour attribute (F2)' do
    let!(:priority_attr) do
      create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                           options: { 'allowed_values' => [{ 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } }] })
    end
    let!(:t1) { make_ticket('status' => 'open') }

    before do
      t1.update_columns(custom_attributes: { 'status' => 'open', 'priority' => 'LEGACY_BOGUS' })
    end

    it 'still merges despite the invalid neighbour (skip_validation)' do
      result, actor = run_merge(source: 'open', target: 'closed')
      expect(result).to be_success
      expect(actor.updated_count).to eq(1)
      expect(t1.reload.get_custom_attribute('status')).to eq('closed')
      expect(t1.reload.get_custom_attribute('priority')).to eq('LEGACY_BOGUS')
    end
  end

  # F4: measure the audit cost of a ~50-ticket merge (one Activity + OutboxEvent per
  # rewritten ticket). The Trackable chain is deliberately kept (audit trail); the
  # measured ratio is reported in the PR.
  describe 'F4 audit-cost measurement (~50 tickets)' do
    before do
      Prosopite.pause
      50.times { create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'open' }) }
      Prosopite.resume
    end

    it 'writes one Activity and one OutboxEvent per rewritten ticket' do
      activities = -> { ActsAsTenant.with_tenant(organisation) { Activity.count } }
      outbox = -> { ActsAsTenant.with_tenant(organisation) { OutboxEvent.count } }

      before_a = activities.call
      before_o = outbox.call
      _result, actor = run_merge(source: 'open', target: 'closed')

      a_delta = activities.call - before_a
      o_delta = outbox.call - before_o
      warn "[F4] 50-ticket merge → Activities=#{a_delta}, OutboxEvents=#{o_delta}"

      expect(actor.updated_count).to eq(50)
      # One status_changed per rewritten ticket. Until #712 the updater_id change
      # added a second, generic "updated" row; that was noise and is gone.
      expect(a_delta).to eq(50)
      expect(o_delta).to eq(50) # 1 OutboxEvent per Activity
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSessionGroupBillingService do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:group) { create(:time_session_group, organisation: organisation, creator: user, billed: false) }
  let(:time_session) { create(:time_session, project: project, creator: user, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Actors::ActorError is defined as a load side-effect of base_actor.rb (not
    # Zeitwerk-autoloadable) — force the load for isolated runs of this spec.
    Actors::BaseActor.name
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '.mark_as_billed' do
    let!(:session1) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: false) }
    let!(:session2) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: false) }

    it 'marks the group as billed' do
      TimeSessionGroupBillingService.mark_as_billed(group, invoice_number: 'INV-001')

      group.reload
      expect(group.billed?).to be true
      expect(group.invoice_number).to eq('INV-001')
      expect(group.billed_at).to be_present
    end

    it 'marks all associated time sessions as billed' do
      TimeSessionGroupBillingService.mark_as_billed(group, invoice_number: 'INV-001')

      session1.reload
      session2.reload
      expect(session1.billed?).to be true
      expect(session2.billed?).to be true
    end

    it 'uses transaction for atomicity' do
      allow(group).to receive(:update!).and_raise(StandardError)

      expect do
        TimeSessionGroupBillingService.mark_as_billed(group, invoice_number: 'INV-001')
      end.to raise_error(StandardError)

      session1.reload
      expect(session1.billed?).to be false
    end
  end

  describe '.mark_as_unbilled' do
    let!(:session1) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: true) }
    let!(:session2) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: true) }

    before do
      group.update!(billed: true, invoice_number: 'INV-001', billed_at: Time.current)
    end

    it 'marks the group as unbilled' do
      TimeSessionGroupBillingService.mark_as_unbilled(group)

      group.reload
      expect(group.billed?).to be false
      expect(group.invoice_number).to be_nil
      expect(group.billed_at).to be_nil
    end

    it 'marks all associated time sessions as unbilled' do
      TimeSessionGroupBillingService.mark_as_unbilled(group)

      session1.reload
      session2.reload
      expect(session1.billed?).to be false
      expect(session2.billed?).to be false
    end
  end

  describe '.add_time_session_to_group' do
    context 'when group is unbilled' do
      it 'adds the session to the group' do
        TimeSessionGroupBillingService.add_time_session_to_group(time_session, group)

        time_session.reload
        expect(time_session.time_session_group).to eq(group)
        expect(time_session.billed?).to be false
      end
    end

    context 'when group is billed' do
      before { group.update!(billed: true, invoice_number: 'INV-001', billed_at: Time.current) }

      it 'adds the session and marks it as billed' do
        TimeSessionGroupBillingService.add_time_session_to_group(time_session, group)

        time_session.reload
        expect(time_session.time_session_group).to eq(group)
        expect(time_session.billed?).to be true
      end
    end
  end

  describe '.remove_time_session_from_group' do
    before do
      time_session.update!(time_session_group: group)
    end

    context 'when session is not billed' do
      it 'removes the session from the group' do
        TimeSessionGroupBillingService.remove_time_session_from_group(time_session)

        time_session.reload
        expect(time_session.time_session_group).to be_nil
        expect(time_session.billed?).to be false
      end
    end

    context 'when session is billed' do
      before { time_session.update!(billed: true) }

      # T3 (plan §9.8-3): coded ActorError instead of a bare StandardError with
      # a hardcoded English message — with_error_mapping maps it to a
      # :session_billed failure instead of :internal_error.
      it 'raises a coded ActorError' do
        expect do
          TimeSessionGroupBillingService.remove_time_session_from_group(time_session)
        end.to raise_error(
          an_instance_of(Actors::ActorError)
            .and(having_attributes(code: :session_billed,
                                   message: I18n.t('services.save_time_session.session_billed')))
        )

        time_session.reload
        expect(time_session.time_session_group).to eq(group)
      end
    end
  end

  describe '.check_consistency' do
    let!(:session1) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: false) }
    let!(:session2) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: false) }

    context 'when all sessions match group status' do
      it 'returns consistent status' do
        result = TimeSessionGroupBillingService.check_consistency(group)

        expect(result[:consistent]).to be true
        expect(result[:message]).to include('consistent')
      end
    end

    context 'when some sessions have mismatched status' do
      before { session1.update_column(:billed, true) }

      it 'returns inconsistent status with details' do
        result = TimeSessionGroupBillingService.check_consistency(group)

        expect(result[:consistent]).to be false
        expect(result[:message]).to include('1 inconsistent')
        expect(result[:session_ids]).to include(session1.id)
      end
    end
  end

  describe '.sync_billed_status' do
    let!(:session1) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: true) }
    let!(:session2) { create(:time_session, project: project, creator: user, organisation: organisation, time_session_group: group, billed: true) }

    before { group.update!(billed: false) }

    it 'syncs all sessions to match group status' do
      TimeSessionGroupBillingService.sync_billed_status(group)

      session1.reload
      session2.reload
      expect(session1.billed?).to be false
      expect(session2.billed?).to be false
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::MoveTicket, type: :service do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:standard_role) { create(:role, organisation: organisation, title: 'Standard User') }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:source_project) { create(:project, organisation: organisation) }
  let(:target_project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role)
    # other_user gets a standard role (NOT admin) so we can test access restrictions
    create(:membership, user: other_user, organisation: organisation, role: standard_role)
    Current.user = user

    # Give users access to source project
    create(:project_permission, user: user, project: source_project, tickets_access: 'read_write')
    create(:project_permission, user: other_user, project: source_project, tickets_access: 'read_write')
  end

  describe '#call' do
    let!(:ticket) do
      create(:ticket, project: source_project, organisation: organisation, creator: user, title: 'Test Ticket')
    end

    context 'happy path' do
      before do
        # Give users access to target project too
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
        create(:project_permission, user: other_user, project: target_project, tickets_access: 'read_write')
      end

      it 'moves the ticket to the target project' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        result = actor.call

        expect(result.success?).to be true
        ticket.reload
        expect(ticket.project_id).to eq(target_project.id)
      end

      it 'assigns a new number in the target project' do
        # Create an existing ticket in target project
        create(:ticket, project: target_project, organisation: organisation, creator: user)

        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        result = actor.call

        expect(result.success?).to be true
        ticket.reload
        expect(ticket.number).to eq(2) # existing ticket is #1
      end

      it 'assigns number 1 for an empty target project' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        result = actor.call

        expect(result.success?).to be true
        ticket.reload
        expect(ticket.number).to eq(1)
      end

      it 'sets updater_id' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        actor.call

        ticket.reload
        expect(ticket.updater_id).to eq(user.id)
      end

      it 'creates activities on source project, target project, and ticket' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)

        expect do
          actor.call
        end.to change(Activity, :count).by(3)

        source_activities = Activity.where(trackable: source_project, action: 'ticket_moved_out')
        target_activities = Activity.where(trackable: target_project, action: 'ticket_moved_in')
        ticket_activities = Activity.where(trackable: ticket, action: 'moved')

        expect(source_activities.count).to eq(1)
        expect(target_activities.count).to eq(1)
        expect(ticket_activities.count).to eq(1)
      end

      it 'sets Current.user during the move and restores the previous value' do
        previous = create(:user)
        Current.user = previous

        described_class.new(ticket: ticket, target_project: target_project, current_user: user).call

        # Restored to the (non-nil) previous; a non-restoring context would leave `user`.
        expect(Current.user).to eq(previous)
        # During the move the activities are attributed via Current.user (= user);
        # a missing with_actor_context would attribute them to `previous`.
        expect(Activity.where(trackable: ticket, action: 'moved').first&.actor).to eq(user)
      end
    end

    context 'with invalid assignments' do
      let!(:assignment) { create(:ticket_assignment, ticket: ticket, user: other_user) }

      before do
        # Give only user access to target project, not other_user
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
      end

      it 'removes assignments for users without access to target project' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        result = actor.call

        expect(result.success?).to be true
        expect(ticket.ticket_assignments.reload.where(user_id: other_user.id)).to be_empty
      end

      it 'does not create unassigned activities for removed assignments' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        actor.call

        unassigned_activities = Activity.where(trackable: ticket, action: 'unassigned')
        expect(unassigned_activities.count).to eq(0)
      end
    end

    context 'with time sessions' do
      let!(:time_session) do
        create(:time_session, ticket: ticket, project: source_project,
                              organisation: organisation, creator: user)
      end

      before do
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
      end

      it 'updates time sessions project_id' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        actor.call

        time_session.reload
        expect(time_session.project_id).to eq(target_project.id)
      end
    end

    context 'with notification subscriptions' do
      before do
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
        # other_user has NO access to target project
        NotificationSubscription.create!(
          user: other_user, subscribable: ticket,
          organisation: organisation, mode: 'follow'
        )
      end

      it 'removes subscriptions for users without access to target project' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        actor.call

        subs = NotificationSubscription.where(subscribable: ticket, user_id: other_user.id)
        expect(subs.count).to eq(0)
      end
    end

    context 'transaction rollback on error' do
      before do
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
      end

      it 'rolls back all changes and reraises in dev/test if activity creation fails' do
        original_project_id = ticket.project_id
        original_number = ticket.number

        # Stub create_activity to raise an unexpected error
        allow_any_instance_of(Project).to receive(:track_ticket_moved_out).and_raise(StandardError, 'boom')

        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)

        # Unexpected errors re-raise in dev/test (prod would log + failure Result).
        expect { actor.call }.to raise_error(StandardError, 'boom')

        ticket.reload
        expect(ticket.project_id).to eq(original_project_id)
        expect(ticket.number).to eq(original_number)
      end
    end

    # Regression guard for the rescue-chain drift: before the failure-mapping
    # was centralised in BaseActor#with_error_mapping, MoveTicket only rescued
    # RecordNotUnique + StandardError, so a RecordInvalid bubbled up as an
    # unexpected error (re-raised in dev/test) instead of a clean failure
    # Result — diverging from the Tier-1 and SaveTicket contracts.
    context 'when the move hits a RecordInvalid (rescue-chain parity)' do
      before do
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
      end

      it 'maps it to a failure result with code :validation_failed instead of re-raising' do
        actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
        allow_any_instance_of(Tickets::Mover).to receive(:perform_move).and_raise(
          ActiveRecord::RecordInvalid.new(Ticket.new.tap(&:validate))
        )

        result = nil
        expect { result = actor.call }.not_to raise_error
        expect(result).not_to be_success
        expect(result.code).to eq(:validation_failed)
      end
    end

    # The RecordNotUnique retry is the entire reason MoveTicket stays Tier-2.
    context 'when the new ticket number keeps colliding (RecordNotUnique retry)' do
      before do
        create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
      end

      it 'retries MAX_RETRIES times then returns a number_conflict failure' do
        attempts = 0
        allow(ticket).to receive(:update_columns) do |*|
          attempts += 1
          raise ActiveRecord::RecordNotUnique, 'duplicate key tickets_project_number'
        end

        # The retry intentionally re-runs perform_move (bounded by MAX_RETRIES);
        # Prosopite would otherwise flag the repeated queries as an N+1.
        Prosopite.pause
        result = described_class.new(ticket: ticket, target_project: target_project, current_user: user).call
        Prosopite.resume

        expect(result).not_to be_success
        expect(attempts).to eq(described_class::MAX_RETRIES)
        expect(result.errors.first).to eq(
          I18n.t('services.actors.move_ticket.number_conflict',
                 retries: described_class::MAX_RETRIES,
                 error: 'duplicate key tickets_project_number')
        )
      end

      it 'recovers and completes the move after a transient RecordNotUnique' do
        attempts = 0
        allow(ticket).to receive(:update_columns).and_wrap_original do |original, *args, **kwargs|
          attempts += 1
          raise ActiveRecord::RecordNotUnique, 'transient' if attempts == 1

          original.call(*args, **kwargs)
        end

        # The retry intentionally re-runs perform_move (bounded by MAX_RETRIES);
        # Prosopite would otherwise flag the repeated queries as an N+1.
        Prosopite.pause
        result = described_class.new(ticket: ticket, target_project: target_project, current_user: user).call
        Prosopite.resume

        expect(result).to be_success
        expect(attempts).to eq(2)
        expect(ticket.reload.project_id).to eq(target_project.id)
      end
    end
  end

  describe '#preflight' do
    let!(:ticket) do
      create(:ticket, project: source_project, organisation: organisation, creator: user, title: 'Preflight Ticket')
    end

    before do
      create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
    end

    it 'returns impact data' do
      actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
      impact = actor.preflight

      expect(impact).to include(
        new_number: 1,
        lost_assignments: [],
        lost_subscriptions: [],
        time_sessions_count: 0
      )
    end

    it 'shows lost assignments for users without target project access' do
      create(:ticket_assignment, ticket: ticket, user: other_user)
      # other_user has NO project permission for target_project

      actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
      impact = actor.preflight

      expect(impact[:lost_assignments].length).to eq(1)
      expect(impact[:lost_assignments].first[:user_name]).to eq(other_user.full_name)
    end

    it 'calculates correct new number with existing tickets' do
      create(:ticket, project: target_project, organisation: organisation, creator: user)
      create(:ticket, project: target_project, organisation: organisation, creator: user)

      actor = described_class.new(ticket: ticket, target_project: target_project, current_user: user)
      impact = actor.preflight

      expect(impact[:new_number]).to eq(3)
    end
  end
end

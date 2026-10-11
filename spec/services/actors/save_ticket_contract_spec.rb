# frozen_string_literal: true

require 'rails_helper'

# Phase 2 migration contract for SaveTicket (Tier 2):
# - check_current_user -> ActorError (non-members get a failure result, not a 500).
#   Untested until now, because all other specs use members as creator.
# - Current.user boundary: SaveTicket wraps its own #call in with_actor_context;
#   removing it would leak Current.user. Tier 1 actors share the template
#   (covered by base_actor_spec), the Tier 2 actors do NOT.
RSpec.describe Actors::SaveTicket, 'membership guard & Current.user boundary' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:member) do
    u = create(:user)
    create(:membership, user: u, organisation: organisation)
    create(:project_permission, user: u, project: project, tickets_access: 'read_write')
    u
  end
  # Deliberately NOT a member of `organisation`.
  let(:non_member) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def call_for(current_user)
    described_class.new(project: project, params: { title: 'Valid title' }, current_user: current_user).call
  end

  describe 'membership guard (check_current_user -> ActorError)' do
    it 'returns a failure with the not_member message (no 500) for a non-member' do
      result = call_for(non_member)

      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('services.actors.not_member'))
    end

    it 'does not persist the ticket for a non-member' do
      expect { call_for(non_member) }.not_to change(Ticket, :count)
    end

    it 'lets a member through (guard does not over-block)' do
      expect { call_for(member) }.to change(Ticket, :count).by(1)
    end
  end

  describe 'Current.user boundary (with_actor_context restore)' do
    # NB: start from a NON-nil previous so the test is not vacuous — a deleted
    # with_actor_context would leave Current.user unchanged, which a nil-start
    # test could not distinguish from a real restore.
    it 'sets Current.user to the actor during the call and restores the previous value' do
      previous = create(:user)
      Current.user = previous

      result = call_for(member)

      expect(result).to be_success
      # Restored to `previous`; a non-restoring context would leave it as `member`.
      expect(Current.user).to eq(previous)
      # ...and DURING the call it was `member`: the created-activity is attributed
      # via Current.user, so a missing with_actor_context would attribute it to
      # `previous`, not `member`.
      expect(Ticket.last.activities.find_by(action: 'created')&.actor).to eq(member)
    end

    it 'restores the previous Current.user even when the call fails (non-member)' do
      previous = create(:user)
      Current.user = previous

      expect(call_for(non_member)).not_to be_success
      expect(Current.user).to eq(previous)
    end
  end
end

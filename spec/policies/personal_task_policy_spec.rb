# frozen_string_literal: true

require 'rails_helper'

# Privacy is the whole point of this model: prove the owner-only wall holds for
# every write action AND that the Scope leaks nothing — explicitly including an
# account_admin (no admin bypass) and a foreign organisation.
RSpec.describe PersonalTaskPolicy, :ci_guard, type: :policy do
  let(:organisation)       { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  let(:admin_role)    { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:owner) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:org_admin) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:other_member) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:task) { create(:personal_task, user: owner, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'owner-gated write actions (show/update/destroy)' do
    %i[show update destroy].each do |action|
      context "##{action}?" do
        it 'permits the owner' do
          expect(described_class.new(owner, task)).to permit_action(action)
        end

        it 'denies a different member' do
          expect(described_class.new(other_member, task)).not_to permit_action(action)
        end

        it 'denies an org admin (NO admin bypass)' do
          expect(described_class.new(org_admin, task)).not_to permit_action(action)
        end
      end
    end
  end

  describe '#index? and #create?' do
    it 'are allowed for any member (the Scope, not the gate, enforces privacy)' do
      expect(described_class.new(other_member, PersonalTask)).to permit_actions(%i[index create])
    end
  end

  describe 'Scope' do
    it 'returns only the current user\'s tasks — never another member\'s (incl. admin view)' do
      mine   = task
      theirs = create(:personal_task, user: other_member, organisation: organisation)

      resolved = PersonalTaskPolicy::Scope.new(owner, PersonalTask).resolve
      expect(resolved).to contain_exactly(mine)
      expect(resolved).not_to include(theirs)

      # An admin resolving the scope sees only THEIR OWN (empty here), not all.
      admin_scope = PersonalTaskPolicy::Scope.new(org_admin, PersonalTask).resolve
      expect(admin_scope).to be_empty
    end

    it 'is additionally walled off cross-tenant (foreign org task never resolves)' do
      mine = task
      ActsAsTenant.with_tenant(other_organisation) do
        create(:personal_task, user: owner, organisation: other_organisation)
      end

      expect(PersonalTaskPolicy::Scope.new(owner, PersonalTask).resolve).to contain_exactly(mine)
    end
  end

  describe 'nil user' do
    it 'raises before any action check (must be logged in)' do
      expect { described_class.new(nil, task) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end

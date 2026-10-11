# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketAttributeDefinitionPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, title: 'account_admin', organisation: organisation)
    end
  end
  let(:user_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, title: 'Standard-Benutzer', organisation: organisation, is_default: true)
    end
  end

  let(:admin_user) { create(:user) }
  let(:regular_user) { create(:user) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
    end
  end
  let!(:user_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: regular_user, organisation: organisation, role: user_role, active: true)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'manage?' do
    context 'when user is account admin' do
      it 'grants access' do
        expect(described_class.new(admin_user, project).manage?).to be_truthy
      end
    end

    context 'when user is regular user' do
      it 'denies access' do
        expect(described_class.new(regular_user, project).manage?).to be_falsey
      end
    end
  end
end

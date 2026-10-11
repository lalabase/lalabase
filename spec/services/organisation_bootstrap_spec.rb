# frozen_string_literal: true

require 'rails_helper'

# Contract spec for OrganisationBootstrap.
#
# What: OrganisationBootstrap.call is duck-typed — it serves BOTH the regular
#   models (Organisation + User, web path via Actors::CreateOrganisation) and the
#   tenant-bypassing admin models (Admin::Organisation + Admin::User, admin path
#   via Actors::CreateUserWithOrganisation). The two families share no ancestor;
#   the only thing binding them is an IMPLICIT interface:
#     - organisation responds to #save! and #find_or_create_account_admin_role
#     - owner        responds to #memberships (a collection answering #create!)
# Why: without this spec a drift in either family (e.g. an Admin:: model losing
#   #find_or_create_account_admin_role) would only surface as a runtime explosion
#   inside the org-creation flow. This pins the contract so the drift fails here,
#   at test time, with a clear message — the cheap alternative to forcing both
#   hierarchies to include a shared module.
RSpec.describe OrganisationBootstrap do
  # respond_to? needs no persistence and no tenant — bare instances suffice, and
  # we deliberately avoid factories so the contract check does not depend on
  # factory internals. Admin:: models bypass acts_as_tenant anyway.
  before { ActsAsTenant.current_tenant = nil }

  shared_examples 'an OrganisationBootstrap target pair' do |org_class, owner_class|
    describe "#{org_class} + #{owner_class}" do
      let(:organisation) { org_class.new }
      let(:owner) { owner_class.new }

      it 'satisfies the organisation half (#save! + #find_or_create_account_admin_role)' do
        expect(organisation).to respond_to(:save!)
        expect(organisation).to respond_to(:find_or_create_account_admin_role)
      end

      it 'satisfies the owner half (#memberships exposing #create!)' do
        expect(owner).to respond_to(:memberships)
        # The PORO calls owner.memberships.create!(...): assert the collection
        # itself answers #create!, not just that #memberships exists.
        expect(owner.memberships).to respond_to(:create!)
      end

      it 'does not answer arbitrary methods (the positive checks are not vacuous)' do
        # Guards against a permissive method_missing making respond_to? always
        # true — which would make this whole contract spec pass for nothing.
        expect(organisation).not_to respond_to(:totally_bogus_contract_method)
        expect(owner).not_to respond_to(:totally_bogus_contract_method)
      end
    end
  end

  describe 'duck-type contract (every caller must satisfy it)' do
    it_behaves_like 'an OrganisationBootstrap target pair', Organisation, User
    it_behaves_like 'an OrganisationBootstrap target pair', Admin::Organisation, Admin::User
  end
end

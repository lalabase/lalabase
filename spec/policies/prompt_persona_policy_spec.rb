# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PromptPersonaPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    user
  end
  let(:regular_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
    user
  end
  let(:other_org_admin) do
    ActsAsTenant.with_tenant(other_organisation) do
      user = create(:user)
      create(:membership, user: user, organisation: other_organisation,
                          role: create(:admin_role, organisation: other_organisation))
      user
    end
  end
  let(:user_without_membership) { create(:user) }

  # The same record evaluated under three ownerships. organisation is the current
  # tenant (set below), so org_owned? holds only for own_persona.
  let(:own_persona)     { create(:prompt_persona, organisation: organisation, key: 'own') }
  let(:global_persona)  { create(:prompt_persona, organisation: nil, key: 'global_only') }
  let(:foreign_persona) { create(:prompt_persona, organisation: other_organisation, key: 'foreign') }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'unauthenticated access' do
    it 'raises Pundit::NotAuthorizedError for a nil user' do
      expect { described_class.new(nil, own_persona) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'raises Pundit::NotAuthorizedError for a nil user in Scope' do
      expect { described_class::Scope.new(nil, PromptPersona) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # index?/new?/create? gate purely on account_admin — the controller forces the
  # record's organisation_id, so no record-level ownership check belongs here.
  describe '#index? / #new? / #create? (account-admin only)' do
    %i[index? new? create?].each do |action|
      it "grants #{action} to an account admin" do
        expect(described_class.new(admin_user, own_persona).public_send(action)).to be true
      end

      it "denies #{action} to a regular member" do
        expect(described_class.new(regular_user, own_persona).public_send(action)).to be false
      end

      it "denies #{action} to an account admin of ANOTHER organisation" do
        expect(described_class.new(other_org_admin, own_persona).public_send(action)).to be false
      end

      it "denies #{action} to a non-member" do
        expect(described_class.new(user_without_membership, own_persona).public_send(action)).to be false
      end
    end

    it 'new? delegates to create?' do
      policy = described_class.new(admin_user, own_persona)
      expect(policy.new?).to eq(policy.create?)
    end
  end

  # update?/edit? require account_admin AND that the record belongs to the current
  # org. Global rows (operator-owned) and other orgs' rows are off limits.
  describe '#update? / #edit? (account admin AND own-org record)' do
    it 'grants update on the org’s OWN persona' do
      expect(described_class.new(admin_user, own_persona).update?).to be true
    end

    it 'DENIES update on a GLOBAL persona (operator territory)' do
      expect(described_class.new(admin_user, global_persona).update?).to be false
    end

    it 'DENIES update on ANOTHER org’s persona (cross-tenant guard)' do
      expect(described_class.new(admin_user, foreign_persona).update?).to be false
    end

    it 'denies update to a regular member, even on the own persona' do
      expect(described_class.new(regular_user, own_persona).update?).to be false
    end

    it 'denies update to an account admin of another organisation' do
      expect(described_class.new(other_org_admin, own_persona).update?).to be false
    end

    it 'edit? delegates to update?' do
      policy = described_class.new(admin_user, own_persona)
      expect(policy.edit?).to eq(policy.update?)
    end
  end

  # destroy? = update?'s ownership rule PLUS a system guard.
  describe '#destroy? (account admin AND own-org AND not system)' do
    it 'grants destroy on the org’s own non-system persona' do
      expect(described_class.new(admin_user, own_persona).destroy?).to be true
    end

    it 'DENIES destroy on a GLOBAL persona' do
      expect(described_class.new(admin_user, global_persona).destroy?).to be false
    end

    it 'DENIES destroy on ANOTHER org’s persona' do
      expect(described_class.new(admin_user, foreign_persona).destroy?).to be false
    end

    it 'DENIES destroy on an own SYSTEM persona (belt-and-suspenders, mirrors prevent_system_destroy)' do
      own_system = create(:prompt_persona, organisation: organisation, key: 'own_sys', system: true)
      expect(described_class.new(admin_user, own_system).destroy?).to be false
    end

    it 'denies destroy to a regular member' do
      expect(described_class.new(regular_user, own_persona).destroy?).to be false
    end
  end

  # The Scope is the read path behind the chat picker — unchanged from v1: every
  # member sees their org's personas + the global pool, active only, never another
  # org's. Independent of the CRUD gates above; account_admin is NOT required.
  describe 'Scope (chat picker pool)' do
    let!(:global)   { create(:prompt_persona, organisation: nil, key: 'overview') }
    let!(:own)      { create(:prompt_persona, organisation: organisation, key: 'own') }
    let!(:foreign)  { create(:prompt_persona, organisation: other_organisation, key: 'foreign') }
    let!(:inactive) { create(:prompt_persona, organisation: organisation, key: 'old', active: false) }

    subject(:resolved) { described_class::Scope.new(regular_user, PromptPersona).resolve }

    it 'includes the global pool and the current org’s personas' do
      expect(resolved).to include(global, own)
    end

    it 'excludes another organisation’s personas (no cross-tenant leak)' do
      expect(resolved).not_to include(foreign)
    end

    it 'excludes inactive personas' do
      expect(resolved).not_to include(inactive)
    end

    it 'returns an empty scope when there is no current tenant' do
      # A bare user (no tenanted membership) so creation does not itself need a
      # tenant — the Scope ignores the user's role anyway, it gates on the tenant.
      ActsAsTenant.current_tenant = nil
      expect(described_class::Scope.new(create(:user), PromptPersona).resolve).to be_empty
    end
  end
end

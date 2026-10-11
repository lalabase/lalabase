# frozen_string_literal: true

require 'rails_helper'

# ProjectRepositoryPolicy authorises managing a project's connected git
# repositories.
#
# Since the "repo-policy-decouple" PR (plan Phase 2), the connected repository is
# treated as a SHARED foundation resource: it feeds project-aware chat grounding
# AND documentation sync. Access is therefore DECOUPLED from the per-org chat-beta
# flag (unlike ChatPolicy, which stays gated) — a user reaches it via chats OR
# documentation rights:
#
#   Read  (index/show — browse the repo list + index history):
#     chats:read OR documentation:write. Deliberately NOT documentation:read
#     (least-privilege — doc *readers* get no repo-page link anywhere in the UI).
#   Write (create/destroy/reindex/update — connect/disconnect/reindex/token rotation):
#     account admin OR chats:write OR documentation:write. All administrative.
#
# The core guarantee this spec pins down: the per-org chat-beta flag must NOT change
# ANY answer this policy gives. The whole matrix runs with the flag ON and OFF and
# expects IDENTICAL results — a beta-flag regression (re-adding `code_indexing_enabled? &&`)
# would break exactly the OFF column and fail loudly here.
RSpec.describe ProjectRepositoryPolicy, :ci_guard, type: :policy do
  # Locals (NOT constants — dynamic constant assignment is illegal inside a block).
  read_actions  = %i[index show].freeze
  write_actions = %i[create destroy reindex update].freeze

  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository)   { create(:project_repository, project: project, organisation: organisation) }

  let(:admin_role)    { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  def role_with_permission(title, action)
    role = create(:role, title: title, organisation: organisation)
    create(:permission, role: role, category: 'projects', action: action, allowed: true)
    role
  end

  let(:chat_writer_role) { role_with_permission('Chat Writer', 'write_access_chats_all_projects') }
  let(:chat_reader_role) { role_with_permission('Chat Reader', 'read_access_chats_all_projects') }
  let(:doc_writer_role)  { role_with_permission('Doc Writer',  'write_access_documentation_all_projects') }
  let(:doc_reader_role)  { role_with_permission('Doc Reader',  'read_access_documentation_all_projects') }

  def user_with_role(role)
    create(:user).tap { |u| create(:membership, user: u, organisation: organisation, role: role, active: true) }
  end

  let(:admin_user)    { user_with_role(admin_role) }
  let(:standard_user) { user_with_role(standard_role) }
  let(:chat_writer)   { user_with_role(chat_writer_role) }
  let(:chat_reader)   { user_with_role(chat_reader_role) }
  let(:doc_writer)    { user_with_role(doc_writer_role) }
  let(:doc_reader)    { user_with_role(doc_reader_role) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # -- Decoupling matrix: identical for chat-beta ON and OFF -------------------
  [true, false].each do |chat_enabled|
    context "with code_indexing_enabled=#{chat_enabled} (flag must not change any answer)" do
      before { organisation.update!(code_indexing_enabled: chat_enabled) }

      describe 'account admin' do
        subject { described_class.new(admin_user, repository) }

        (read_actions + write_actions).each do |action|
          it { is_expected.to permit_action(action) }
        end
      end

      describe 'chats:write user (write implies read → full access)' do
        subject { described_class.new(chat_writer, repository) }

        (read_actions + write_actions).each do |action|
          it { is_expected.to permit_action(action) }
        end
      end

      describe 'chats:read user (read-only)' do
        subject { described_class.new(chat_reader, repository) }

        read_actions.each  { |action| it { is_expected.to permit_action(action) } }
        write_actions.each { |action| it { is_expected.not_to permit_action(action) } }
      end

      describe 'documentation:write user (the decouple target — manages via docs alone)' do
        subject { described_class.new(doc_writer, repository) }

        (read_actions + write_actions).each do |action|
          it { is_expected.to permit_action(action) }
        end
      end

      describe 'documentation:read user (least-privilege decision: DENIED everywhere)' do
        subject { described_class.new(doc_reader, repository) }

        # Deliberate decision, not a side effect: doc *readers* get no repo access
        # at all. If someone loosens read to documentation:read, this breaks and
        # forces the choice back into the open.
        (read_actions + write_actions).each do |action|
          it { is_expected.not_to permit_action(action) }
        end
      end

      describe 'user with neither chat nor documentation access' do
        subject { described_class.new(standard_user, repository) }

        (read_actions + write_actions).each do |action|
          it { is_expected.not_to permit_action(action) }
        end
      end
    end
  end

  # -- Explicit decoupling headline (crisp anchor next to the matrix) ----------
  describe 'decoupling headline: chat-beta OFF no longer blocks repo management' do
    before { organisation.update!(code_indexing_enabled: false) }

    it 'an account admin can still manage the repo with chat disabled' do
      expect(described_class.new(admin_user, repository).create?).to be(true)
    end

    it 'a documentation:write user can manage the repo with chat disabled' do
      expect(described_class.new(doc_writer, repository).create?).to be(true)
    end
  end

  describe 'new? aliases create? (Pundit convention)' do
    it 'returns the same value as create? for a writer user' do
      pol = described_class.new(chat_writer, repository)
      expect(pol.new?).to eq(pol.create?)
    end
  end

  describe 'destroy?, reindex?, update? and create? are symmetric (same write gate)' do
    # If someone splits the gate (e.g. tightens destroy to admin-only, or loosens
    # reindex/update to read access), these break and force an explicit decision.
    %i[admin_user standard_user chat_reader chat_writer doc_writer doc_reader].each do |sym|
      it "#{sym}: destroy?, reindex? and update? all equal create?" do
        pol = described_class.new(send(sym), repository)
        expect(pol.destroy?).to eq(pol.create?)
        expect(pol.reindex?).to eq(pol.create?)
        expect(pol.update?).to eq(pol.create?)
      end
    end
  end

  describe 'inactive memberships' do
    let(:inactive_doc_writer) do
      u = create(:user)
      create(:membership, user: u, organisation: organisation, role: doc_writer_role, active: false)
      u
    end

    it 'cannot create — membership must be active' do
      expect(described_class.new(inactive_doc_writer, repository).create?).to be(false)
    end

    it 'cannot even read — membership must be active' do
      expect(described_class.new(inactive_doc_writer, repository).index?).to be(false)
    end

    # The asymmetry this used to pin is GONE (#603). account_admin_in? now requires an
    # active membership, so the account_admin? short-circuit no longer carries a
    # deactivated admin past the write actions. The note stays because its reasoning
    # is what made the fix necessary: the gap was only ever covered by the controller
    # (set_project authorises :show? first), and the warning it carried, a reuse of
    # this policy WITHOUT that guard on an API/MCP/batch path, is being built. Both
    # halves are pinned so the asymmetry cannot come back unnoticed.
    let(:inactive_admin) do
      u = create(:user)
      create(:membership, user: u, organisation: organisation, role: admin_role, active: false)
      u
    end

    it 'inactive admin is denied WRITE (the account_admin? short-circuit requires active membership)' do
      expect(described_class.new(inactive_admin, repository).create?).to be(false)
    end

    it 'inactive admin is denied READ (area_access? requires active membership)' do
      expect(described_class.new(inactive_admin, repository).index?).to be(false)
    end
  end

  describe 'per-project permission precedence (delegates to ProjectAccessService)' do
    # read_access?/write_access? delegate to area_access?, where a project-level
    # ProjectPermission overrides the global role grant. The decoupling matrix above
    # only exercises global roles; these pin the project-permission path too.
    it 'denies a GLOBAL chats:write user whose project has a no_access override' do
      ProjectPermission.create!(user: chat_writer, project: project, chats_access: 'no_access')
      pol = described_class.new(chat_writer, repository)
      expect(pol.create?).to be(false)
      expect(pol.index?).to be(false)
    end

    it 'permits a user whose ONLY grant is a project-level documentation read_write' do
      user = user_with_role(standard_role)
      ProjectPermission.create!(user: user, project: project, documentation_access: 'read_write')
      pol = described_class.new(user, repository)
      expect(pol.create?).to be(true)
      expect(pol.index?).to be(true)
    end

    it 'denies a user with only project-level documentation read_only (least-privilege at the project layer)' do
      user = user_with_role(standard_role)
      ProjectPermission.create!(user: user, project: project, documentation_access: 'read_only')
      pol = described_class.new(user, repository)
      expect(pol.index?).to be(false)
      expect(pol.create?).to be(false)
    end
  end

  describe 'cross-tenant isolation (predicate level, not just scope)' do
    it 'denies an admin of a DIFFERENT organisation against this org’s repo' do
      other = create(:organisation)
      foreign_admin = create(:user)
      other_admin_role = create(:role, title: 'account_admin', organisation: other)
      create(:membership, user: foreign_admin, organisation: other, role: other_admin_role, active: true)

      pol = described_class.new(foreign_admin, repository)
      expect(pol.create?).to be(false)
      expect(pol.index?).to be(false)
    end
  end

  describe '#initialize raises when user is nil' do
    it 'rejects anonymous access (defense in depth)' do
      expect { described_class.new(nil, repository) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe 'Scope resolution (decoupled: union of chats:read and documentation:write)' do
    let!(:other_org)     { create(:organisation) }
    let!(:other_project) { create(:project, organisation: other_org) }
    let!(:foreign_repo) do
      ActsAsTenant.with_tenant(other_org) { create(:project_repository, project: other_project) }
    end

    # The scope plucks project_ids EAGERLY at resolve time, so the repo (and its
    # project) must exist BEFORE we resolve — force it for every example here.
    before { repository }

    def resolve_for(user)
      described_class::Scope.new(user, ProjectRepository).resolve
    end

    it 'admin sees all repos in their org, never a foreign-org repo (tenant isolation)' do
      scope = resolve_for(admin_user)
      expect(scope).to include(repository)
      expect(scope).not_to include(foreign_repo)
    end

    it 'chats:read user sees the repo' do
      expect(resolve_for(chat_reader)).to include(repository)
    end

    it 'documentation:write user sees the repo (decouple target — via docs alone)' do
      expect(resolve_for(doc_writer)).to include(repository)
    end

    it 'documentation:read user sees nothing (least-privilege)' do
      expect(resolve_for(doc_reader)).to be_empty
    end

    it 'standard user with no access sees nothing' do
      expect(resolve_for(standard_user)).to be_empty
    end

    it 'the chat-beta flag does NOT empty the scope (decoupled from ChatFeatureGated)' do
      organisation.update!(code_indexing_enabled: false)
      expect(resolve_for(admin_user)).to include(repository)
      expect(resolve_for(doc_writer)).to include(repository)
    end

    it 'is fail-closed without a tenant — never leaks a populated scope' do
      # policy_scope always runs inside a tenant; acts_as_tenant require_tenant makes
      # a tenant-less repo query fail closed (raise) rather than silently return all
      # rows. This pins that safety property for the repo scope specifically.
      admin_user # must exist before we drop the tenant (repo already forced above)
      ActsAsTenant.current_tenant = nil
      expect { described_class::Scope.new(admin_user, ProjectRepository).resolve }
        .to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end
  end
end

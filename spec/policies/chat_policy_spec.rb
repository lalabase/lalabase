# frozen_string_literal: true

require 'rails_helper'

# projekt_chat_abbau rewrote this file, and the shape of the rewrite is the point.
#
# It used to answer for TWO surfaces and was structured accordingly: roughly the
# first thousand lines described the per-project chat (the `chats` project area, the
# per-org beta flag, global readers and writers, project overrides, archived
# projects), and one describe at the bottom described the org-wide personal thread.
# The project chat is gone. What is left is one surface with ONE gate, so the file
# is now short enough to read in one sitting -- which is the only state in which a
# rights spec is actually reviewed.
#
# The gate is the §13-2 PAIR, asked in full every time: the organisation's
# `assistant_enabled` flag AND the person's `use_assistant` permission AND an active
# membership. Ownership decides the rest, with deliberately NO account_admin bypass
# (§13-1, "persönlich ist persönlich").
#
# ⚠️ What this file must keep proving after the cut, because it is the easy thing to
# lose in a removal: the `chats` PROJECT AREA is no longer asked. It still exists and
# still decides repository visibility (ProjectRepositoryPolicy::Scope, `chats:read OR
# documentation:write`), which is what the code tools resolve their reach through --
# but it decides nothing here any more. The examples under "the project area decides
# nothing here" pin exactly that, in both directions.
RSpec.describe ChatPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation, assistant_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) do
    # account_admin? is detected by title.
    create(:role, title: 'account_admin', organisation: organisation)
  end

  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:assistant_role) do
    role = create(:role, title: 'Assistant User', organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    role
  end

  let(:owner) { member_with(assistant_role) }
  let(:colleague) { member_with(assistant_role) }
  let(:admin_user) { member_with(admin_role) }
  let(:plain_user) { member_with(standard_role) }

  let(:own_thread) { create(:chat, organisation: organisation, user: owner) }
  let(:foreign_thread) { create(:chat, organisation: organisation, user: colleague) }

  def member_with(role, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'ownership decides show/update/destroy' do
    context 'the owner' do
      subject { described_class.new(owner, own_thread) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:update) }
      it { is_expected.to permit_action(:destroy) }
    end

    context 'a colleague who may use the assistant themselves' do
      subject { described_class.new(colleague, own_thread) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    # §13-1, decided 23.08.2026. Stronger than tenant scoping: user-private INSIDE
    # the org. An explicit, logged path in the admin backend stays possible later;
    # a silent scope bypass is not it.
    context 'an account_admin who is not the owner' do
      subject { described_class.new(admin_user, foreign_thread) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'an account_admin who IS the owner' do
      # account_admin? answers has_permission? with true, so no explicit
      # use_assistant row is needed -- but ownership still decides.
      subject { described_class.new(admin_user, create(:chat, organisation: organisation, user: admin_user)) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:destroy) }
    end

    # A thread with NO owner belongs to nobody, not to everybody.
    #
    # ⚠️ projekt_chat_abbau made that shape UNREACHABLE, and it is worth saying out
    # loud because it is a strengthening nobody planned. `org_thread_has_owner` read
    # `return if project_id.present? || user_id.present?`, so it bound project-less
    # threads only; the DB check constraint chats_org_thread_requires_user says the
    # same thing. With no thread carrying a project any more, both bind EVERY row.
    # An ownerless chat can no longer be written through the model, and not through
    # a raw update either.
    #
    # The policy's fail-closed answer stays pinned all the same, on an in-memory
    # record that needs no database: rows written before this cut may still exist,
    # and #owner? is the floor under them.
    context 'a thread without an owner' do
      it 'cannot be created, at the model level and at the database level' do
        expect { create(:chat, organisation: organisation, user: nil) }
          .to raise_error(ActiveRecord::RecordInvalid, /Verlauf/)

        saved = create(:chat, organisation: organisation, user: owner)
        expect { saved.update_column(:user_id, nil) }
          .to raise_error(ActiveRecord::StatementInvalid, /chats_org_thread_requires_user/)
      end

      it 'would be readable by nobody if one still existed' do
        ownerless = Chat.new(organisation: organisation)

        expect(described_class.new(colleague, ownerless)).not_to permit_action(:show)
        expect(described_class.new(admin_user, ownerless)).not_to permit_action(:show)
        expect(described_class.new(owner, ownerless)).not_to permit_action(:show)
      end
    end
  end

  describe 'the §13-2 pair gates every action' do
    context 'the operator flag is off' do
      before { organisation.update!(assistant_enabled: false) }

      subject { described_class.new(owner, own_thread) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:index) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }

      it 'empties the scope, for the owner and for an admin' do
        own_thread
        expect(ChatPolicy::Scope.new(owner, Chat).resolve).to be_empty
        expect(ChatPolicy::Scope.new(admin_user, Chat).resolve).to be_empty
      end
    end

    context 'the role lacks use_assistant' do
      let(:plain_thread) { create(:chat, organisation: organisation, user: plain_user) }

      subject { described_class.new(plain_user, plain_thread) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }

      it 'is scoped out as well' do
        expect(ChatPolicy::Scope.new(plain_user, Chat).resolve).not_to include(plain_thread)
      end
    end

    # role_in_organisation (behind has_permission?) does not ask membership.active,
    # so assistant_gate_open? checks it explicitly. This pins that seam rather than
    # trusting Organisations::BaseController to catch it first: a gate that only
    # holds because something upstream catches it is not a gate.
    context 'a deactivated owner' do
      before { owner.memberships.find_by(organisation: organisation).update!(active: false) }

      subject { described_class.new(owner, own_thread) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:destroy) }

      it 'is scoped out as well, not just denied' do
        expect(ChatPolicy::Scope.new(owner, Chat).resolve).not_to include(own_thread)
      end
    end

    context 'a deactivated account_admin' do
      let(:inactive_admin) { member_with(admin_role, active: false) }

      it 'is denied AND scoped out' do
        own_thread
        expect(described_class.new(inactive_admin, own_thread)).not_to permit_action(:show)
        expect(ChatPolicy::Scope.new(inactive_admin, Chat).resolve).to be_empty
      end
    end
  end

  # ⚠️ The load-bearing assertion of projekt_chat_abbau in this file. Before the cut
  # every one of these answers depended on the project's `chats` area; a person
  # without a ProjectPermission could not reach their own thread. There is no project
  # on a thread any more, so the area decides nothing here -- and the two directions
  # are pinned separately, because a policy that quietly started asking again would
  # only be caught by one of them.
  describe 'the project area decides nothing here' do
    it 'lets the owner reach their own thread with no project permission at all' do
      expect(ProjectPermission.where(user: owner)).to be_empty
      expect(described_class.new(owner, own_thread)).to permit_action(:show)
      expect(ChatPolicy::Scope.new(owner, Chat).resolve).to include(own_thread)
    end

    it 'does not hand a colleague the thread even with full chats access to the project' do
      ProjectPermission.create!(user: colleague, project: project, chats_access: 'read_write')

      expect(described_class.new(colleague, own_thread)).not_to permit_action(:show)
      expect(ChatPolicy::Scope.new(colleague, Chat).resolve).not_to include(own_thread)
    end

    it 'keeps the own thread reachable when the chats area is revoked' do
      permission = ProjectPermission.create!(user: owner, project: project, chats_access: 'read_write')
      own_thread
      permission.update!(chats_access: 'no_access')

      expect(described_class.new(owner, own_thread.reload)).to permit_action(:show)
      expect(ChatPolicy::Scope.new(owner, Chat).resolve).to include(own_thread)
    end
  end

  describe 'index? and create?' do
    it 'gives the surface to anyone the pair lets in' do
      expect(described_class.new(owner, Chat)).to permit_action(:index)
      expect(described_class.new(owner, Chat.new(user: owner, organisation: organisation)))
        .to permit_action(:create)
    end

    it 'refuses the surface without the permission' do
      expect(described_class.new(plain_user, Chat)).not_to permit_action(:index)
    end

    # T2 hardening (second-review finding on T1): create? must not authorize a thread
    # whose owner is somebody else -- otherwise a controller that forgot to force the
    # owner server-side would pass authorization for a record its caller could never
    # read.
    it 'refuses creating a thread for somebody else' do
      foreign = Chat.new(user: colleague, organisation: organisation)

      expect(described_class.new(owner, foreign)).not_to permit_action(:create)
    end

    it 'allows an ownerless stand-in (Actors::SaveChat sets the owner server-side)' do
      standin = Chat.new(organisation: organisation)

      expect(described_class.new(owner, standin)).to permit_action(:create)
    end
  end

  # new? delegates to create?, edit? to update? (ApplicationPolicy). create? asks the
  # pair, update? asks the pair AND ownership, so the two deliberately do not answer
  # alike for a class-level record.
  describe 'new? / edit? delegation' do
    it 'permits new? on the pair and refuses edit? on a record that is not yours' do
      expect(described_class.new(owner, Chat.new(user: owner, organisation: organisation)))
        .to permit_action(:new)
      expect(described_class.new(colleague, own_thread)).not_to permit_action(:edit)
    end

    it 'refuses both without the permission' do
      expect(described_class.new(plain_user, Chat.new(organisation: organisation)))
        .not_to permit_action(:new)
    end
  end

  describe 'scope' do
    let!(:mine) { own_thread }
    let!(:theirs) { foreign_thread }

    it 'resolves the threads of the asking user and nothing else' do
      resolved = ChatPolicy::Scope.new(owner, Chat).resolve

      expect(resolved).to include(mine)
      expect(resolved).not_to include(theirs)
    end

    it 'does not hand an account_admin everybody elses threads' do
      expect(ChatPolicy::Scope.new(admin_user, Chat).resolve).not_to include(mine, theirs)
    end

    # ⚠️ The boundary the scope must state as well as the doors do. A pre-cut SHARED
    # thread (a row WITH a project) cannot be written any more, but a database that
    # predates projekt_chat_abbau can hold one -- and MessageComponent#redacted?
    # short-circuits for the owner unconditionally now, so a row handed out here would
    # render in full. Planted as a raw column, the way such a row exists.
    it 'leaves out a legacy row that still carries a project, even for its owner' do
      legacy = create(:chat, organisation: organisation, user: owner)
      legacy.update_column(:project_id, project.id)

      expect(ChatPolicy::Scope.new(owner, Chat).resolve).not_to include(legacy)
      expect(ChatPolicy::Scope.new(owner, Chat).resolve).to include(mine)
    end
  end

  describe 'cross-tenant isolation' do
    let(:other_organisation) { create(:organisation, assistant_enabled: true) }

    let(:outsider) do
      user = create(:user)
      role = create(:role, title: 'account_admin', organisation: other_organisation)
      create(:membership, user: user, organisation: other_organisation, role: role, active: true)
      user
    end

    it 'denies an admin of a different organisation every action' do
      subject = described_class.new(outsider, own_thread)

      expect(subject).not_to permit_action(:show)
      expect(subject).not_to permit_action(:index)
      expect(subject).not_to permit_action(:create)
      expect(subject).not_to permit_action(:update)
      expect(subject).not_to permit_action(:destroy)
    end

    it 'returns only chats of the current organisation' do
      own_thread
      foreign_elsewhere = ActsAsTenant.with_tenant(other_organisation) do
        create(:chat, organisation: other_organisation, user: outsider)
      end

      resolved = ChatPolicy::Scope.new(owner, Chat).resolve

      expect(resolved).to include(own_thread)
      expect(resolved).not_to include(foreign_elsewhere)
    end
  end

  describe 'defensive edges' do
    it 'raises Pundit::NotAuthorizedError for a nil user, on the policy and on the scope' do
      expect { described_class.new(nil, own_thread) }.to raise_error(Pundit::NotAuthorizedError)
      expect { ChatPolicy::Scope.new(nil, Chat.all) }.to raise_error(Pundit::NotAuthorizedError)
    end

    # Two different right answers, and the asymmetry is deliberate rather than an
    # oversight. The POLICY is asked about a record somebody already holds, so it
    # answers "no" quietly. The SCOPE would have to run a query, and acts_as_tenant
    # refuses an untenanted one loudly -- which is the behaviour we want: a list
    # built without a tenant is a bug, not an empty page.
    it 'denies without raising when there is no current tenant, and refuses to LIST at all' do
      own_thread
      owner
      ActsAsTenant.current_tenant = nil

      expect(described_class.new(owner, own_thread).show?).to be(false)
      expect { ChatPolicy::Scope.new(owner, Chat).resolve }
        .to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end

    it 'follows the rights of the organisation the thread belongs to, not another one' do
      elsewhere = create(:organisation, assistant_enabled: true)
      admin_elsewhere = create(:role, title: 'account_admin', organisation: elsewhere)
      create(:membership, user: plain_user, organisation: elsewhere, role: admin_elsewhere, active: true)

      expect(described_class.new(plain_user, own_thread)).not_to permit_action(:show)
    end
  end
end

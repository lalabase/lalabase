# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImportFilePolicy, :ci_guard, type: :policy do
  # The flag is ON here because the existing examples below ask the OTHER question:
  # "who may import in an organisation where importing is available at all?". The
  # gate itself gets its own section at the bottom.
  let(:organisation) { create(:organisation, data_import_enabled: true) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:non_member) { create(:user) }

  # CodebaseImportFile needs no real record for policy tests,
  # since all checks are based only on #import_permitted?.
  let(:record) { CodebaseImportFile.new(organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # =========================================================================
  # All actions are admin-only — tested compactly
  # =========================================================================
  describe 'standard CRUD actions' do
    %i[index show create new update edit destroy].each do |action|
      describe "##{action}?" do
        it 'permits for admin' do
          expect(described_class.new(admin_user, record)).to permit_action(action)
        end

        it 'denies for standard member' do
          expect(described_class.new(standard_user, record)).not_to permit_action(action)
        end

        it 'denies for non-member' do
          expect(described_class.new(non_member, record)).not_to permit_action(action)
        end
      end
    end
  end

  describe 'custom import actions' do
    %i[
      preview_import execute_import select_project
      preview_tickets execute_tickets_import
      preview_time_sessions execute_time_sessions_import
      rollback execute_rollback
      assign_uploads execute_upload_assignment
    ].each do |action|
      describe "##{action}?" do
        it 'permits for admin' do
          expect(described_class.new(admin_user, record).public_send(:"#{action}?")).to be true
        end

        it 'denies for standard member' do
          expect(described_class.new(standard_user, record).public_send(:"#{action}?")).to be false
        end
      end
    end
  end

  # =========================================================================
  # Scope
  # =========================================================================
  describe CodebaseImportFilePolicy::Scope do
    subject { described_class.new(scoped_user, CodebaseImportFile).resolve }

    context 'as admin' do
      let(:scoped_user) { admin_user }

      it 'returns all records' do
        expect(subject).to eq(CodebaseImportFile.all)
      end
    end

    context 'as standard member' do
      let(:scoped_user) { standard_user }

      it 'returns none' do
        expect(subject).to eq(CodebaseImportFile.none)
      end
    end

    context 'as non-member' do
      let(:scoped_user) { non_member }

      it 'returns none' do
        expect(subject).to eq(CodebaseImportFile.none)
      end
    end
  end

  # =========================================================================
  # Operator gate: data_import_enabled
  # =========================================================================
  # The tab and the menu entry are hidden when the flag is off, but hiding an
  # entrance does not close a route: every POST below stays reachable by URL.
  # So the gate is pinned HERE, on the policy, and across ALL actions rather
  # than on index? alone, because a copied predicate is exactly how one action
  # would keep answering true.
  describe 'when the organisation has data import switched off' do
    let(:organisation) { create(:organisation) }

    it 'defaults to off for a fresh organisation' do
      expect(organisation.data_import_enabled?).to be(false)
    end

    it 'denies every action, even for an account admin' do
      policy = described_class.new(admin_user, record)

      denied = CodebaseImportFilePolicy.instance_methods(false).select { |m| m.to_s.end_with?('?') }
      expect(denied).not_to be_empty

      denied.each do |action|
        expect(policy.public_send(action)).to be(false), "expected #{action} to be refused while the flag is off"
      end
    end

    it 'resolves the scope to nothing for an account admin' do
      expect(CodebaseImportFilePolicy::Scope.new(admin_user, CodebaseImportFile).resolve)
        .to eq(CodebaseImportFile.none)
    end
  end

  # =========================================================================
  # nil user
  # =========================================================================
  describe 'with nil user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect do
        described_class.new(nil, record)
      end.to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
end

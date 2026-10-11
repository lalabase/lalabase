# frozen_string_literal: true

require 'rails_helper'

# MeetingAnalysisPolicy — PostPolicy 1:1 (E17). Proves the two invariants the
# whole slice rests on:
#   1. the :meetings AREA gate runs FIRST — a user without meetings-read cannot see
#      even a PUBLISHED analysis by direct id (the UUID-bypass negative, Codex-OV);
#   2. per-creator visibility on top — a private analysis is visible only to its
#      creator, a published one to every meetings-reader.
# Writes (create/publish/unpublish/destroy) are :meetings-write, not creator-only;
# changing a PRIVATE analysis also needs being able to read it.
RSpec.describe MeetingAnalysisPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: admin_user) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:meetings_reader_role) do
    role = create(:role, title: 'Meetings Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_meetings_all_projects', allowed: true)
    role
  end

  let(:meetings_writer_role) do
    role = create(:role, title: 'Meetings Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_meetings_all_projects', allowed: true)
    role
  end

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

  let(:reader_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_reader_role, active: true)
    user
  end

  let(:other_reader) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_reader_role, active: true)
    user
  end

  let(:writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_writer_role, active: true)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Analyses authored by reader_user; foreign_private is authored by other_reader.
  let(:own_private) { create(:meeting_analysis, meeting: meeting, creator: reader_user, is_private: true) }
  let(:foreign_private) { create(:meeting_analysis, meeting: meeting, creator: other_reader, is_private: true) }
  let(:published) { create(:meeting_analysis, :published, meeting: meeting, creator: other_reader) }

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, own_private) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe '#show? — area gate first, then visibility' do
    it 'lets the creator see their own private analysis' do
      expect(described_class.new(reader_user, own_private).show?).to be(true)
    end

    it 'hides a foreign private analysis from another meetings-reader' do
      expect(described_class.new(reader_user, foreign_private).show?).to be(false)
    end

    it 'shows a published analysis to any meetings-reader' do
      expect(described_class.new(reader_user, published).show?).to be(true)
      expect(described_class.new(other_reader, published).show?).to be(true)
    end

    it 'lets an account admin see even a foreign private analysis' do
      expect(described_class.new(admin_user, foreign_private).show?).to be(true)
    end

    # The UUID-bypass negative: the area gate runs BEFORE visibility, so a user
    # without meetings-read cannot reach a PUBLISHED analysis by guessed id.
    it 'denies a user without meetings-read even a published analysis (no bypass)' do
      expect(described_class.new(standard_user, published).show?).to be(false)
    end
  end

  describe 'write actions (:meetings-write, not creator-only)' do
    it 'permits create/update/publish/unpublish/destroy for a writer' do
      policy = described_class.new(writer_user, published)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.publish?).to be(true)
      expect(policy.unpublish?).to be(true)
      expect(policy.destroy?).to be(true)
    end

    it 'lets a writer delete a private analysis they did NOT create (org content)' do
      # foreign_private authored by other_reader; writer_user may still curate it.
      expect(described_class.new(writer_user, foreign_private).destroy?).to be(true)
    end

    # Changing it is different: publishing (is_private = 0) or re-running a
    # private analysis the writer cannot even read would expose or rewrite
    # someone else's private work.
    it 'does not let a writer publish or re-run a private analysis they cannot read' do
      policy = described_class.new(writer_user, foreign_private)
      expect(policy.update?).to be(false)
      expect(policy.publish?).to be(false)
    end

    it 'lets a writer publish their own private analysis' do
      own = create(:meeting_analysis, meeting: meeting, creator: writer_user, is_private: true)
      policy = described_class.new(writer_user, own)
      expect(policy.update?).to be(true)
      expect(policy.publish?).to be(true)
    end

    it 'lets an account admin change a foreign private analysis' do
      expect(described_class.new(admin_user, foreign_private).update?).to be(true)
    end

    it 'denies writes to a reader' do
      policy = described_class.new(reader_user, published)
      expect(policy.create?).to be(false)
      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
    end

    it 'permits writes for an account admin' do
      policy = described_class.new(admin_user, foreign_private)
      expect(policy.destroy?).to be(true)
    end
  end

  describe 'Scope' do
    before do
      own_private
      foreign_private
      published
    end

    def resolved(user)
      described_class::Scope.new(user, MeetingAnalysis).resolve
    end

    it 'returns the creator their own private analysis and the published one, not foreign private' do
      result = resolved(reader_user)
      expect(result).to include(own_private, published)
      expect(result).not_to include(foreign_private)
    end

    it 'returns another reader only the published analysis (and their own foreign_private)' do
      result = resolved(other_reader)
      expect(result).to include(foreign_private, published)
      expect(result).not_to include(own_private)
    end

    it 'returns nothing to a user without meetings-read (no project scope)' do
      expect(resolved(standard_user)).to be_empty
    end

    it 'returns everything to an account admin' do
      expect(resolved(admin_user)).to include(own_private, foreign_private, published)
    end
  end
end

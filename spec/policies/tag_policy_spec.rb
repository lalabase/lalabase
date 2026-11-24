# frozen_string_literal: true

require 'rails_helper'

# The tags of an organisation are looked after in the management section "Tags",
# by its account admins only (user, 2026-11-24). Until then the creator of a tag
# could rename and delete it as well. The scope stays what the tag field's
# suggestions and the bulk change read: every tag for an admin, the tags of the
# reader's projects for everyone else.
RSpec.describe TagPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

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

  let(:other_org_admin) do
    other_role = create(:role, title: 'account_admin', organisation: other_organisation)
    user = create(:user)
    create(:membership, user: user, organisation: other_organisation, role: other_role, active: true)
    user
  end

  # The creator of the tag: no right of its own any more.
  let(:owned_tag) { create(:tag, organisation: organisation, user_id: standard_user.id) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, owned_tag) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  %i[index? update? edit? merge? destroy?].each do |question|
    describe "##{question}" do
      it 'permits an account admin' do
        expect(described_class.new(admin_user, owned_tag).public_send(question)).to be(true)
      end

      it 'refuses a member, also the one who created the tag' do
        expect(described_class.new(standard_user, owned_tag).public_send(question)).to be(false)
      end

      it 'refuses the admin of another organisation' do
        expect(described_class.new(other_org_admin, owned_tag).public_send(question)).to be(false)
      end
    end
  end

  # Nobody creates a tag by hand: it comes into being by tagging.
  it 'answers no to creating and showing, for an admin too' do
    policy = described_class.new(admin_user, Tag.new)

    expect([policy.create?, policy.new?, policy.show?]).to all(be(false))
  end

  describe TagPolicy::Scope do
    let(:accessible_project) { create(:project, organisation: organisation) }
    let(:foreign_project) { create(:project, organisation: organisation) }

    let!(:accessible_tag) do
      tag = create(:tag, organisation: organisation)
      create(:tagging, tag: tag, taggable: create(:ticket, project: accessible_project, organisation: organisation))
      tag
    end

    let!(:foreign_tag) do
      tag = create(:tag, organisation: organisation)
      create(:tagging, tag: tag, taggable: create(:ticket, project: foreign_project, organisation: organisation))
      tag
    end

    before do
      create(:project_permission, user: standard_user, project: accessible_project, tickets_access: 'read_only')
    end

    it 'returns all tags for an org admin, unused ones too' do
      unused = create(:tag, organisation: organisation)

      expect(described_class.new(admin_user, Tag).resolve).to include(accessible_tag, foreign_tag, unused)
    end

    it 'returns only tags used in accessible projects for a standard user' do
      result = described_class.new(standard_user, Tag).resolve
      expect(result).to include(accessible_tag)
      expect(result).not_to include(foreign_tag)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:admin_user) { create(:user) }
  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) do
      Role.find_or_create_account_admin(organisation)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # Setup users in organisation
    create(:membership, user: user1, organisation: organisation)
    create(:membership, user: user2, organisation: organisation)
    create(:membership, user: admin_user, organisation: organisation, role: admin_role)

    # Grant project permissions
    create(:project_permission, user: user1, project: project, tickets_access: :read_write)
    create(:project_permission, user: user2, project: project, tickets_access: :read_write)
    create(:project_permission, user: admin_user, project: project, tickets_access: :read_write)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'privacy permissions' do
    let(:public_post) do
      create(:post, ticket: ticket, user: user1, is_private: false)
    end

    let(:private_post_user1) do
      create(:post, ticket: ticket, user: user1, is_private: true)
    end

    let(:private_post_user2) do
      create(:post, ticket: ticket, user: user2, is_private: true)
    end

    describe '#show?' do
      context 'public posts' do
        it 'allows any user with project access to view' do
          expect(PostPolicy.new(user1, public_post).show?).to be true
          expect(PostPolicy.new(user2, public_post).show?).to be true
        end
      end

      context 'private posts' do
        it 'allows creator to view their private post' do
          expect(PostPolicy.new(user1, private_post_user1).show?).to be true
        end

        it 'prevents other users from viewing private posts' do
          expect(PostPolicy.new(user2, private_post_user1).show?).to be false
        end

        it 'allows admin to view any private post' do
          expect(admin_user.account_admin_in?(organisation)).to be true
          expect(PostPolicy.new(admin_user, private_post_user1).show?).to be true
          expect(PostPolicy.new(admin_user, private_post_user2).show?).to be true
        end
      end
    end

    describe '#update?' do
      context 'public posts' do
        it 'allows creator to update their post' do
          expect(PostPolicy.new(user1, public_post).update?).to be true
        end

        it 'prevents other users from updating posts' do
          expect(PostPolicy.new(user2, public_post).update?).to be false
        end
      end

      context 'private posts' do
        it 'allows creator to update their private post' do
          expect(PostPolicy.new(user1, private_post_user1).update?).to be true
        end

        it 'prevents other users from updating private posts' do
          expect(PostPolicy.new(user2, private_post_user1).update?).to be false
        end

        it 'allows admin to update any private post' do
          expect(PostPolicy.new(admin_user, private_post_user1).update?).to be true
          expect(PostPolicy.new(admin_user, private_post_user2).update?).to be true
        end
      end
    end

    describe '#destroy?' do
      context 'public posts' do
        it 'allows creator to delete their post' do
          expect(PostPolicy.new(user1, public_post).destroy?).to be true
        end

        it 'prevents other users from deleting posts' do
          expect(PostPolicy.new(user2, public_post).destroy?).to be false
        end
      end

      context 'private posts' do
        it 'allows creator to delete their private post' do
          expect(PostPolicy.new(user1, private_post_user1).destroy?).to be true
        end

        it 'prevents other users from deleting private posts' do
          expect(PostPolicy.new(user2, private_post_user1).destroy?).to be false
        end

        it 'allows admin to delete any private post' do
          expect(PostPolicy.new(admin_user, private_post_user1).destroy?).to be true
          expect(PostPolicy.new(admin_user, private_post_user2).destroy?).to be true
        end
      end
    end
  end

  describe PostPolicy::Scope do
    let!(:public_post) do
      create(:post, ticket: ticket, user: user1, is_private: false)
    end

    let!(:private_post_user1) do
      create(:post, ticket: ticket, user: user1, is_private: true)
    end

    let!(:private_post_user2) do
      create(:post, ticket: ticket, user: user2, is_private: true)
    end

    it 'shows public posts to all users' do
      scope1 = PostPolicy::Scope.new(user1, Post.all).resolve
      scope2 = PostPolicy::Scope.new(user2, Post.all).resolve

      expect(scope1).to include(public_post)
      expect(scope2).to include(public_post)
    end

    it 'shows private posts only to their creators' do
      scope1 = PostPolicy::Scope.new(user1, Post.all).resolve
      scope2 = PostPolicy::Scope.new(user2, Post.all).resolve

      expect(scope1).to include(private_post_user1)
      expect(scope1).not_to include(private_post_user2)

      expect(scope2).to include(private_post_user2)
      expect(scope2).not_to include(private_post_user1)
    end

    it 'shows all posts to admin users' do
      scope = PostPolicy::Scope.new(admin_user, Post.all).resolve

      expect(scope).to include(public_post, private_post_user1, private_post_user2)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Post, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      # Setup users in organisation
      create(:membership, user: user1, organisation: organisation)
      create(:membership, user: user2, organisation: organisation)
    end
  end

  describe 'privacy functionality' do
    describe 'scopes' do
      let!(:public_post) do
        ActsAsTenant.with_tenant(organisation) do
          create(:post, ticket: ticket, user: user1, is_private: false)
        end
      end

      let!(:private_post_user1) do
        ActsAsTenant.with_tenant(organisation) do
          create(:post, ticket: ticket, user: user1, is_private: true)
        end
      end

      let!(:private_post_user2) do
        ActsAsTenant.with_tenant(organisation) do
          create(:post, ticket: ticket, user: user2, is_private: true)
        end
      end

      describe '.public_posts' do
        it 'returns only public posts' do
          ActsAsTenant.with_tenant(organisation) do
            expect(Post.public_posts).to contain_exactly(public_post)
          end
        end
      end

      describe '.private_posts' do
        it 'returns only private posts' do
          ActsAsTenant.with_tenant(organisation) do
            expect(Post.private_posts).to contain_exactly(private_post_user1, private_post_user2)
          end
        end
      end
    end

    describe 'instance methods' do
      describe '#private?' do
        it 'returns true for private posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: true)
            expect(post.private?).to be true
          end
        end

        it 'returns false for public posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: false)
            expect(post.private?).to be false
          end
        end
      end

      describe '#public?' do
        it 'returns false for private posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: true)
            expect(post.public?).to be false
          end
        end

        it 'returns true for public posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: false)
            expect(post.public?).to be true
          end
        end
      end
    end

    describe 'callbacks and validations' do
      describe 'set_visible_to_user_on_private callback' do
        it 'sets visible_to_user to the post creator for private posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: true)
            expect(post.visible_to_user).to eq(user1)
          end
        end

        it 'clears visible_to_user for public posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: false)
            expect(post.visible_to_user).to be_nil
          end
        end

        it 'updates visible_to_user when privacy changes' do
          ActsAsTenant.with_tenant(organisation) do
            post = create(:post, ticket: ticket, user: user1, is_private: false)
            expect(post.visible_to_user).to be_nil

            post.update!(is_private: true)
            expect(post.visible_to_user).to eq(user1)

            post.update!(is_private: false)
            expect(post.visible_to_user).to be_nil
          end
        end
      end

      describe 'private_post_visibility_consistency validation' do
        it 'passes validation for properly configured private posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = build(:post, ticket: ticket, user: user1, is_private: true)
            expect(post).to be_valid
          end
        end

        it 'passes validation for public posts' do
          ActsAsTenant.with_tenant(organisation) do
            post = build(:post, ticket: ticket, user: user1, is_private: false)
            expect(post).to be_valid
          end
        end
      end
    end
  end
end

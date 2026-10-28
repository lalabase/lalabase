# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PowerSearchService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Test Ticket') }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      # Setup users in organisation
      create(:membership, user: user1, organisation: organisation)
      create(:membership, user: user2, organisation: organisation)
      # Both need project access so that the global search returns hits.
      # This spec checks private post visibility, not project access.
      create(:project_permission, user: user1, project: project, tickets_access: 'read_only')
      create(:project_permission, user: user2, project: project, tickets_access: 'read_only')
    end
    # Since PR 5 the similarity vectors come from the sidecar — see the twin comment
    # in power_search_service_spec.rb for why this stub is setup noise, not behaviour.
    stub_default_embedding_space
  end

  describe 'private posts privacy in search' do
    let!(:public_post) do
      ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: user1, is_private: false, content: 'öffentlicher geheimer inhalt')
        create(:fragment, fragmentable: post, plain_text_content: 'öffentlicher geheimer inhalt', organisation: organisation)
        post
      end
    end

    let!(:private_post_user1) do
      ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: user1, is_private: true, content: 'privater geheimer inhalt von user1')
        create(:fragment, fragmentable: post, plain_text_content: 'privater geheimer inhalt von user1', organisation: organisation)
        post
      end
    end

    let!(:private_post_user2) do
      ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: user2, is_private: true, content: 'privater geheimer inhalt von user2')
        create(:fragment, fragmentable: post, plain_text_content: 'privater geheimer inhalt von user2', organisation: organisation)
        post
      end
    end

    describe 'cannot find private posts from other users' do
      it 'user1 cannot find private posts from user2' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new('geheimer', organisation, project.id, user1)
          results = service.execute

          # Filter only post results
          post_results = results.select { |result| result[:type] == :post }

          # User1 should see public posts and their own private posts
          expect(post_results.map { |r| r[:title] }).to include(ticket.title) # public post

          # Verify that private posts from user2 are NOT found
          post_links = post_results.map { |r| r[:link] }
          ticket_path = Rails.application.routes.url_helpers.organisation_project_ticket_path(
            organisation, project, ticket
          )

          # Should contain the ticket path (for public or own private posts)
          expect(post_links).to include(ticket_path)

          # But the content should not contain user2's private content
          post_contents = post_results.map { |r| r[:content] }
          expect(post_contents.join).not_to include('privater geheimer inhalt von user2')
        end
      end

      it 'user2 cannot find private posts from user1' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new('geheimer', organisation, project.id, user2)
          results = service.execute

          # Filter only post results
          post_results = results.select { |result| result[:type] == :post }

          # User2 should see public posts and their own private posts
          expect(post_results.map { |r| r[:title] }).to include(ticket.title) # public post

          # But the content should not contain user1's private content
          post_contents = post_results.map { |r| r[:content] }
          expect(post_contents.join).not_to include('privater geheimer inhalt von user1')
        end
      end

      it 'users can find their own private posts' do
        ActsAsTenant.with_tenant(organisation) do
          # User1 searches for their own private content
          service1 = described_class.new('privater geheimer inhalt von user1', organisation, project.id, user1)
          results1 = service1.execute

          post_results1 = results1.select { |result| result[:type] == :post }
          expect(post_results1.size).to be > 0
          expect(post_results1.map { |r| r[:content] }.join).to include('privater geheimer inhalt von user1')

          # User2 searches for their own private content
          service2 = described_class.new('privater geheimer inhalt von user2', organisation, project.id, user2)
          results2 = service2.execute

          post_results2 = results2.select { |result| result[:type] == :post }
          expect(post_results2.size).to be > 0
          expect(post_results2.map { |r| r[:content] }.join).to include('privater geheimer inhalt von user2')
        end
      end

      it 'users cannot search for specific private content from other users' do
        ActsAsTenant.with_tenant(organisation) do
          # User1 tries to search specifically for user2's private content
          service = described_class.new('privater geheimer inhalt von user2', organisation, project.id, user1)
          results = service.execute

          post_results = results.select { |result| result[:type] == :post }

          # No post results should be found that contain user2's private content
          post_contents = post_results.map { |r| r[:content] }
          expect(post_contents.join).not_to include('privater geheimer inhalt von user2')
        end
      end

      it 'anonymous users cannot find any posts' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new('geheimer', organisation, project.id, nil)
          results = service.execute

          post_results = results.select { |result| result[:type] == :post }

          # Without an authenticated user there is no project access -> no hits
          # (more restrictive than before; PowerSearch requires auth anyway).
          expect(post_results).to be_empty
        end
      end
    end

    describe 'global search without project filter' do
      it 'respects privacy across all projects' do
        ActsAsTenant.with_tenant(organisation) do
          # Global search without project filter
          service = described_class.new('geheimer', organisation, nil, user1)
          results = service.execute

          post_results = results.select { |result| result[:type] == :post }
          post_contents = post_results.map { |r| r[:content] }
          combined_content = post_contents.join

          # User1 should see public and their own private posts
          expect(combined_content).to include('öffentlicher geheimer inhalt')
          expect(combined_content).to include('privater geheimer inhalt von user1')

          # But not user2's private posts
          expect(combined_content).not_to include('privater geheimer inhalt von user2')
        end
      end
    end

    describe 'edge cases' do
      it 'handles search when user has no private posts' do
        ActsAsTenant.with_tenant(organisation) do
          user3 = create(:user)
          create(:membership, user: user3, organisation: organisation)
          create(:project_permission, user: user3, project: project, tickets_access: 'read_only')

          service = described_class.new('geheimer', organisation, project.id, user3)
          results = service.execute

          post_results = results.select { |result| result[:type] == :post }
          post_contents = post_results.map { |r| r[:content] }
          combined_content = post_contents.join

          # User3 should see only public posts
          expect(combined_content).to include('öffentlicher geheimer inhalt')
          expect(combined_content).not_to include('privater geheimer inhalt von user1')
          expect(combined_content).not_to include('privater geheimer inhalt von user2')
        end
      end

      it 'handles empty search results gracefully' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new('nonexistent search term', organisation, project.id, user1)
          results = service.execute

          expect(results).to be_an(Array)
          expect(results).to be_empty
        end
      end
    end
  end
end

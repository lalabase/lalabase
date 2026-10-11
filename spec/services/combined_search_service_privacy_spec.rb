# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CombinedSearchService, type: :service do
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

      # CombinedSearchService gates results on ProjectPolicy::Scope (security
      # hardening, commit 77edd112): a bare org membership is NOT project access.
      # Without an explicit per-project grant, accessible_project_ids is empty,
      # the access filter short-circuits to .none, and EVERY search returns [] —
      # so the privacy assertions below never even reach the is_private filter
      # they mean to test. Give both members read access to `project`; the
      # per-post is_private / visible_to_user_id filter (the real subject here) is
      # independent of project-level access.
      [user1, user2].each do |member|
        create(:project_permission, user: member, project: project,
                                    tickets_access: 'read_only', notes_access: 'read_only',
                                    documents_access: 'read_only', chats_access: 'read_only')
      end
    end
  end

  describe 'privacy filtering in search results' do
    let!(:public_post) do
      ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: user1, is_private: false, content: 'public searchable content')
        create(:fragment, fragmentable: post, plain_text_content: 'public searchable content', organisation: organisation)
        post
      end
    end

    let!(:private_post_user1) do
      ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: user1, is_private: true, content: 'private searchable content user1')
        create(:fragment, fragmentable: post, plain_text_content: 'private searchable content user1', organisation: organisation)
        post
      end
    end

    let!(:private_post_user2) do
      ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: user2, is_private: true, content: 'private searchable content user2')
        create(:fragment, fragmentable: post, plain_text_content: 'private searchable content user2', organisation: organisation)
        post
      end
    end

    describe 'project-scoped search' do
      it 'includes public posts for all users' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new(
            organisation: organisation,
            query: 'searchable',
            embedding: nil,
            current_user: user1,
            project_id: project.id
          )

          results = service.call
          post_fragments = results.select { |f| f.fragmentable_type == 'Post' }

          expect(post_fragments.map(&:fragmentable)).to include(public_post)
        end
      end

      it 'includes only user\'s own private posts' do
        ActsAsTenant.with_tenant(organisation) do
          # Search as user1
          service1 = described_class.new(
            organisation: organisation,
            query: 'searchable',
            embedding: nil,
            current_user: user1,
            project_id: project.id
          )

          results1 = service1.call
          post_fragments1 = results1.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts1 = post_fragments1.map(&:fragmentable)

          expect(fragmentable_posts1).to include(private_post_user1)
          expect(fragmentable_posts1).not_to include(private_post_user2)

          # Search as user2
          service2 = described_class.new(
            organisation: organisation,
            query: 'searchable',
            embedding: nil,
            current_user: user2,
            project_id: project.id
          )

          results2 = service2.call
          post_fragments2 = results2.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts2 = post_fragments2.map(&:fragmentable)

          expect(fragmentable_posts2).to include(private_post_user2)
          expect(fragmentable_posts2).not_to include(private_post_user1)
        end
      end
    end

    describe 'global search (no project filter)' do
      it 'applies privacy filter without project scope' do
        ActsAsTenant.with_tenant(organisation) do
          # Search as user1 without project filter
          service = described_class.new(
            organisation: organisation,
            query: 'searchable',
            embedding: nil,
            current_user: user1,
            project_id: nil
          )

          results = service.call
          post_fragments = results.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts = post_fragments.map(&:fragmentable)

          expect(fragmentable_posts).to include(public_post)
          expect(fragmentable_posts).to include(private_post_user1)
          expect(fragmentable_posts).not_to include(private_post_user2)
        end
      end

      it 'returns nothing for a nil (unauthenticated) user — fails closed, not open' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new(
            organisation: organisation,
            query: 'searchable',
            embedding: nil,
            current_user: nil,
            project_id: nil
          )

          # Post-hardening (commit 77edd112): no current_user means no accessible
          # projects, so the search returns NOTHING rather than leaking even public
          # posts to an anonymous caller. This path is unreachable in practice — the
          # only caller, PowerSearchController, is authenticated — but the service
          # must fail closed. (The old test asserted the pre-hardening behaviour
          # "nil user sees public posts", which the access filter no longer allows.)
          expect(service.call).to be_empty
        end
      end
    end

    describe 'specific privacy search scenarios' do
      it 'finds private posts when searching for private content by creator' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new(
            organisation: organisation,
            query: 'private',
            embedding: nil,
            current_user: user1,
            project_id: project.id
          )

          results = service.call
          post_fragments = results.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts = post_fragments.map(&:fragmentable)

          expect(fragmentable_posts).to include(private_post_user1)
          expect(fragmentable_posts).not_to include(private_post_user2)
        end
      end

      it 'does not find private posts when searching by non-creator' do
        ActsAsTenant.with_tenant(organisation) do
          service = described_class.new(
            organisation: organisation,
            query: 'private searchable content user1',
            embedding: nil,
            current_user: user2,
            project_id: project.id
          )

          results = service.call
          post_fragments = results.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts = post_fragments.map(&:fragmentable)

          expect(fragmentable_posts).not_to include(private_post_user1)
        end
      end

      it 'cannot find private posts from other users even with exact content search' do
        ActsAsTenant.with_tenant(organisation) do
          # User2 tries to search for exactly User1's private content
          service = described_class.new(
            organisation: organisation,
            query: 'private searchable content user1',
            embedding: nil,
            current_user: user2,
            project_id: project.id
          )

          results = service.call
          post_fragments = results.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts = post_fragments.map(&:fragmentable)

          # User2 should not be able to find private_post_user1
          expect(fragmentable_posts).not_to include(private_post_user1)

          # But User2 should be able to find their own private posts
          service_own = described_class.new(
            organisation: organisation,
            query: 'private searchable content user2',
            embedding: nil,
            current_user: user2,
            project_id: project.id
          )

          results_own = service_own.call
          post_fragments_own = results_own.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts_own = post_fragments_own.map(&:fragmentable)

          expect(fragmentable_posts_own).to include(private_post_user2)
        end
      end

      it 'verifies complete privacy isolation between users' do
        ActsAsTenant.with_tenant(organisation) do
          # Create additional private posts for a better test
          private_post_user1_secret = create(:post, ticket: ticket, user: user1, is_private: true, content: 'user1 secret information')
          create(:fragment, fragmentable: private_post_user1_secret, plain_text_content: 'user1 secret information', organisation: organisation)

          private_post_user2_secret = create(:post, ticket: ticket, user: user2, is_private: true, content: 'user2 secret information')
          create(:fragment, fragmentable: private_post_user2_secret, plain_text_content: 'user2 secret information', organisation: organisation)

          # User1 searches for "secret" - should only find their own private posts
          service1 = described_class.new(
            organisation: organisation,
            query: 'secret',
            embedding: nil,
            current_user: user1,
            project_id: project.id
          )

          results1 = service1.call
          post_fragments1 = results1.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts1 = post_fragments1.map(&:fragmentable)

          expect(fragmentable_posts1).to include(private_post_user1_secret)
          expect(fragmentable_posts1).not_to include(private_post_user2_secret)

          # User2 searches for "secret" - should only find their own private posts
          service2 = described_class.new(
            organisation: organisation,
            query: 'secret',
            embedding: nil,
            current_user: user2,
            project_id: project.id
          )

          results2 = service2.call
          post_fragments2 = results2.select { |f| f.fragmentable_type == 'Post' }
          fragmentable_posts2 = post_fragments2.map(&:fragmentable)

          expect(fragmentable_posts2).to include(private_post_user2_secret)
          expect(fragmentable_posts2).not_to include(private_post_user1_secret)
        end
      end
    end
  end

  # DocumentationPage is gated on the :documentation area right, NOT on general
  # project visibility — documentation_access defaults to no_access, so a plain
  # project member must not see doc excerpts in search results (leak + 403 on click).
  # user1 (set up in the top-level before) HAS project access but NO doc grant, which
  # is exactly the member-without-right case.
  describe 'documentation access filtering' do
    let(:doc_reader) { create(:user) }
    let(:documentation_set) do
      ActsAsTenant.with_tenant(organisation) { create(:documentation_set, project: project, organisation: organisation) }
    end

    let!(:doc_page) do
      ActsAsTenant.with_tenant(organisation) do
        page = create(:documentation_page, documentation_set: documentation_set, organisation: organisation,
                                           title: 'Deployment Guide', markdown_body: 'searchable doc content')
        create(:fragment, fragmentable: page, plain_text_content: 'searchable doc content', organisation: organisation)
        page
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: doc_reader, organisation: organisation)
        create(:project_permission, user: doc_reader, project: project, documentation_access: 'read_only')
      end
    end

    def doc_pages_found_by(user)
      ActsAsTenant.with_tenant(organisation) do
        described_class.new(
          organisation: organisation, query: 'searchable', embedding: nil,
          current_user: user, project_id: nil
        ).call.select { |f| f.fragmentable_type == 'DocumentationPage' }.map(&:fragmentable)
      end
    end

    it 'includes documentation pages for a user with :documentation read' do
      expect(doc_pages_found_by(doc_reader)).to include(doc_page)
    end

    it 'excludes documentation for a project member without the :documentation right' do
      expect(doc_pages_found_by(user1)).not_to include(doc_page)
    end

    it 'excludes a soft-removed documentation page even for an authorized reader' do
      ActsAsTenant.with_tenant(organisation) { doc_page.update!(removed_at: Time.current) }
      expect(doc_pages_found_by(doc_reader)).not_to include(doc_page)
    end

    it 'does not leak documentation of a project the reader has no doc right in' do
      other_page = ActsAsTenant.with_tenant(organisation) do
        other_project = create(:project, organisation: organisation)
        other_set = create(:documentation_set, project: other_project, organisation: organisation)
        page = create(:documentation_page, documentation_set: other_set, organisation: organisation,
                                           title: 'Foreign', markdown_body: 'searchable doc content')
        create(:fragment, fragmentable: page, plain_text_content: 'searchable doc content', organisation: organisation)
        page
      end

      expect(doc_pages_found_by(doc_reader)).not_to include(other_page)
    end
  end

  # Meetings (Gespräche Slice 6) are gated on the :meetings area right (default
  # no_access, like documentation) AND on the per-meeting create_embeddings opt-in.
  # A plain project member (user1: has project access, no meetings grant) must never
  # see meeting content in search — the PII fail-closed path (plan §7).
  describe 'meetings access filtering' do
    let(:meetings_reader) { create(:user) }

    let!(:opted_in_meeting) do
      ActsAsTenant.with_tenant(organisation) do
        meeting = create(:meeting, project: project, organisation: organisation, creator: user1,
                                   create_embeddings: true, notes: 'searchable meeting content')
        create(:fragment, fragmentable: meeting, plain_text_content: 'searchable meeting content', organisation: organisation)
        meeting
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: meetings_reader, organisation: organisation)
        create(:project_permission, user: meetings_reader, project: project, meetings_access: 'read_only')
      end
    end

    def meetings_found_by(user)
      ActsAsTenant.with_tenant(organisation) do
        described_class.new(
          organisation: organisation, query: 'searchable', embedding: nil,
          current_user: user, project_id: nil
        ).call.select { |f| f.fragmentable_type == 'Meeting' }.map(&:fragmentable)
      end
    end

    it 'includes an opted-in meeting for a user with :meetings read' do
      expect(meetings_found_by(meetings_reader)).to include(opted_in_meeting)
    end

    it 'excludes meeting content for a project member WITHOUT the :meetings right (PII fail-closed)' do
      expect(meetings_found_by(user1)).not_to include(opted_in_meeting)
    end

    it 'excludes an opted-OUT meeting even for a :meetings reader (create_embeddings = false)' do
      opted_out = ActsAsTenant.with_tenant(organisation) do
        meeting = create(:meeting, project: project, organisation: organisation, creator: user1,
                                   create_embeddings: false, notes: 'searchable opted out content')
        create(:fragment, fragmentable: meeting, plain_text_content: 'searchable opted out content', organisation: organisation)
        meeting
      end
      expect(meetings_found_by(meetings_reader)).not_to include(opted_out)
    end

    it 'does not leak a meeting from a project the reader has no :meetings right in' do
      other_meeting = ActsAsTenant.with_tenant(organisation) do
        other_project = create(:project, organisation: organisation)
        meeting = create(:meeting, project: other_project, organisation: organisation, creator: user1,
                                   create_embeddings: true, notes: 'searchable foreign meeting')
        create(:fragment, fragmentable: meeting, plain_text_content: 'searchable foreign meeting', organisation: organisation)
        meeting
      end
      expect(meetings_found_by(meetings_reader)).not_to include(other_meeting)
    end
  end

  # Meeting analyses (Gespräche Slice 7b) share the :meetings area gate with meetings,
  # PLUS a per-analysis row filter: only published (is_private = false) AND search-
  # released (include_in_search = true) analyses are findable — INDEPENDENT of the
  # meeting's own create_embeddings opt-in (D13 redaction use-case). A private analysis
  # never surfaces in ANY user's search, not even its creator's (Entscheidung 5).
  describe 'meeting analyses access filtering' do
    let(:meetings_reader) { create(:user) }
    # Intentionally NOT opted into search — proves the analysis embeds independently (D13).
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: user1, create_embeddings: false)
      end
    end

    let!(:released_analysis) do
      ActsAsTenant.with_tenant(organisation) do
        analysis = create(:meeting_analysis, :published, meeting: meeting, organisation: organisation,
                                                         creator: user1, include_in_search: true,
                                                         content: 'searchable analysis content')
        create(:fragment, fragmentable: analysis, plain_text_content: 'searchable analysis content',
                          organisation: organisation)
        analysis
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: meetings_reader, organisation: organisation)
        create(:project_permission, user: meetings_reader, project: project, meetings_access: 'read_only')
      end
    end

    def analyses_found_by(user)
      ActsAsTenant.with_tenant(organisation) do
        described_class.new(
          organisation: organisation, query: 'searchable', embedding: nil,
          current_user: user, project_id: nil
        ).call.select { |f| f.fragmentable_type == 'MeetingAnalysis' }.map(&:fragmentable)
      end
    end

    it 'includes a published+search-released analysis for a :meetings reader (independent of the meeting opt-in)' do
      expect(analyses_found_by(meetings_reader)).to include(released_analysis)
    end

    it 'excludes analysis content for a project member WITHOUT the :meetings right' do
      expect(analyses_found_by(user1)).not_to include(released_analysis)
    end

    # Entscheidung 5 (DER Kern): a private analysis is never findable in search — not even
    # by its creator, who CAN see it in the UI (visible_to). Search exposure ⊂ UI visibility.
    it 'excludes a private analysis even for its own creator (Entscheidung 5)' do
      private_analysis = ActsAsTenant.with_tenant(organisation) do
        analysis = create(:meeting_analysis, meeting: meeting, organisation: organisation,
                                             creator: meetings_reader, is_private: true,
                                             include_in_search: true, content: 'searchable private analysis')
        create(:fragment, fragmentable: analysis, plain_text_content: 'searchable private analysis',
                          organisation: organisation)
        analysis
      end
      expect(analyses_found_by(meetings_reader)).not_to include(private_analysis)
    end

    it 'excludes a published analysis that is NOT search-released (include_in_search = false)' do
      not_released = ActsAsTenant.with_tenant(organisation) do
        analysis = create(:meeting_analysis, :published, meeting: meeting, organisation: organisation,
                                                         creator: user1, include_in_search: false,
                                                         content: 'searchable not released')
        create(:fragment, fragmentable: analysis, plain_text_content: 'searchable not released',
                          organisation: organisation)
        analysis
      end
      expect(analyses_found_by(meetings_reader)).not_to include(not_released)
    end

    it 'does not leak an analysis from a project the reader has no :meetings right in' do
      other_analysis = ActsAsTenant.with_tenant(organisation) do
        other_project = create(:project, organisation: organisation)
        other_meeting = create(:meeting, project: other_project, organisation: organisation, creator: user1)
        analysis = create(:meeting_analysis, :published, meeting: other_meeting, organisation: organisation,
                                                         creator: user1, include_in_search: true,
                                                         content: 'searchable foreign analysis')
        create(:fragment, fragmentable: analysis, plain_text_content: 'searchable foreign analysis',
                          organisation: organisation)
        analysis
      end
      expect(analyses_found_by(meetings_reader)).not_to include(other_analysis)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the project-access leak in the global PowerSearch:
# CombinedSearchService used to scope fragments only by organisation, so a user
# with access to project A could find content from project B via the global search.
# The service must restrict fragments to the projects the current_user may read
# (single source of truth: ProjectPolicy::Scope), while keeping the org scope as
# defense-in-depth and the existing private-post filter intact.
RSpec.describe CombinedSearchService do
  let(:organisation) { create(:organisation) }
  let(:project_a) { create(:project, organisation: organisation) }
  let(:project_b) { create(:project, organisation: organisation) }

  let(:standard_role) do
    create(:role, title: 'Standard User', organisation: organisation, is_default: true)
  end

  let(:admin_role) do
    create(:role, title: 'account_admin', organisation: organisation)
  end

  let(:user) do
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    u
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  # Grants the user read access to a project via a local ProjectPermission.
  def grant_access(user, project)
    create(:project_permission, user: user, project: project, tickets_access: 'read_only')
  end

  # Builds a searchable ticket fragment in the given project.
  def ticket_fragment(project, content)
    ticket = create(:ticket, project: project, organisation: organisation, creator: user)
    create(:fragment, fragmentable: ticket, organisation: organisation, plain_text_content: content)
  end

  def run(project_id: nil, current_user: user)
    described_class.new(
      organisation: organisation,
      query: 'zebradiscovery',
      embedding: nil,
      current_user: current_user,
      project_id: project_id
    ).call
  end

  describe 'global search (no project_id)' do
    let!(:fragment_a) { ticket_fragment(project_a, 'zebradiscovery alpha content') }
    let!(:fragment_b) { ticket_fragment(project_b, 'zebradiscovery bravo content') }

    it 'excludes fragments from projects the user cannot access' do
      grant_access(user, project_a)

      results = run

      expect(results).to include(fragment_a)
      expect(results).not_to include(fragment_b)
    end

    it 'includes fragments from every project the user can access' do
      grant_access(user, project_a)
      grant_access(user, project_b)

      results = run

      expect(results).to include(fragment_a, fragment_b)
    end

    it 'returns nothing when the user has access to no project' do
      results = run

      expect(results).to be_empty
    end

    it 'returns nothing for an anonymous (nil) user even with fragments present' do
      # accessible_project_ids guard: current_user.nil? => [] => no matches.
      # A mutation that removes the nil guard would break here with a NoMethodError.
      results = run(current_user: nil)

      expect(results).to be_empty
    end

    it 'lets org admins search across all projects (not locked out)' do
      admin = create(:user)
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)

      results = run(current_user: admin)

      expect(results).to include(fragment_a, fragment_b)
    end
  end

  describe 'private-post filter still applies within an accessible project' do
    it 'hides private posts not addressed to the user but keeps public ones' do
      grant_access(user, project_a)
      ticket = create(:ticket, project: project_a, organisation: organisation, creator: user)

      public_post  = create(:post, ticket: ticket, organisation: organisation, is_private: false)
      private_post = create(:post, ticket: ticket, organisation: organisation, is_private: true, visible_to_user_id: nil)

      public_fragment  = create(:fragment, fragmentable: public_post, organisation: organisation,
                                           plain_text_content: 'zebradiscovery public post')
      private_fragment = create(:fragment, fragmentable: private_post, organisation: organisation,
                                           plain_text_content: 'zebradiscovery private post')

      results = run

      expect(results).to include(public_fragment)
      expect(results).not_to include(private_fragment)
    end

    it 'follows Post.readable_by: addressee and author read, nobody else' do
      # Since 27.09.2026 the author reads a private post they addressed to someone
      # else (decision in the private-comment slice; it used to be invisible to them).
      # A post between two other people stays invisible, whichever column is checked.
      grant_access(user, project_a)
      author = create(:user)
      third = create(:user)
      [author, third].each do |member|
        create(:membership, user: member, organisation: organisation, role: standard_role, active: true)
      end
      ticket = create(:ticket, project: project_a, organisation: organisation, creator: user)

      addressed_to_me = create(:post, ticket: ticket, organisation: organisation, user: author,
                                      is_private: true, visible_to_user_id: user.id)
      authored_by_me  = create(:post, ticket: ticket, organisation: organisation, user: user,
                                      is_private: true, visible_to_user_id: author.id)
      between_others  = create(:post, ticket: ticket, organisation: organisation, user: author,
                                      is_private: true, visible_to_user_id: third.id)

      to_me_fragment   = create(:fragment, fragmentable: addressed_to_me, organisation: organisation,
                                           plain_text_content: 'zebradiscovery addressed to me')
      by_me_fragment   = create(:fragment, fragmentable: authored_by_me, organisation: organisation,
                                           plain_text_content: 'zebradiscovery authored by me')
      others_fragment  = create(:fragment, fragmentable: between_others, organisation: organisation,
                                           plain_text_content: 'zebradiscovery between others')

      results = run

      expect(results).to include(to_me_fragment, by_me_fragment)
      expect(results).not_to include(others_fragment)
    end
  end

  describe 'post (comment) fragments respect project access via the shared polymorphic JOIN' do
    # So far ALL post tests build in project_a and check only the is_private filter — never the
    # CROSS-PROJECT path. The post→ticket join (Fragment::FRAGMENTABLE_PROJECT_JOINS, post_tickets
    # alias) is covered cross-project on the RAG side, but NOT on THIS one (power search). A
    # corruption of the post_tickets join would leak a project B comment — unguarded.
    it 'excludes a public post on a ticket of an INACCESSIBLE project (no cross-project leak)' do
      grant_access(user, project_a)
      ticket_b = create(:ticket, project: project_b, organisation: organisation, creator: user)
      post_b   = create(:post, ticket: ticket_b, organisation: organisation, is_private: false)
      leak     = create(:fragment, fragmentable: post_b, organisation: organisation,
                                   plain_text_content: 'zebradiscovery leaked comment')

      expect(run).not_to include(leak)
    end

    it 'includes a public post on a ticket of the ACCESSIBLE project (join resolves to project_id, not all-or-nothing)' do
      grant_access(user, project_a)
      ticket_a = create(:ticket, project: project_a, organisation: organisation, creator: user)
      post_a   = create(:post, ticket: ticket_a, organisation: organisation, is_private: false)
      hit      = create(:fragment, fragmentable: post_a, organisation: organisation,
                                   plain_text_content: 'zebradiscovery visible comment')

      expect(run).to include(hit)
    end
  end

  describe 'project_id parameter is authorized against the user' do
    let!(:fragment_a) { ticket_fragment(project_a, 'zebradiscovery alpha content') }
    let!(:fragment_b) { ticket_fragment(project_b, 'zebradiscovery bravo content') }

    it 'returns nothing when project_id points to a project the user cannot access' do
      grant_access(user, project_a)

      results = run(project_id: project_b.id)

      expect(results).to be_empty
    end

    it 'returns matches when project_id points to an accessible project' do
      grant_access(user, project_b)

      results = run(project_id: project_b.id)

      expect(results).to include(fragment_b)
    end

    it 'narrows to ONLY the requested project even when more projects are accessible' do
      # The user may see A and B, but searches specifically in A: B matches must NOT
      # appear. Catches the mutation that, when project_id is present, falls back to all
      # accessible projects (instead of only the requested one).
      grant_access(user, project_a)
      grant_access(user, project_b)

      results = run(project_id: project_a.id)

      expect(results).to include(fragment_a)
      expect(results).not_to include(fragment_b)
    end
  end

  describe 'tenant isolation' do
    it 'never returns fragments from a different organisation' do
      grant_access(user, project_a)
      ticket_fragment(project_a, 'zebradiscovery alpha content')

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        other_ticket = create(:ticket, project: other_project, organisation: other_org,
                                       creator: create(:user))
        create(:fragment, fragmentable: other_ticket, organisation: other_org,
                          plain_text_content: 'zebradiscovery foreign content')
      end

      results = run

      expect(results.map(&:organisation_id).uniq).to eq([organisation.id])
    end
  end

  # Shared-JOIN boundary guard (Slice 3): Fragment::FRAGMENTABLE_PROJECT_JOINS gained
  # documentation_pages/documentation_sets JOINs for the chat RAG, and this service
  # reuses that constant. But its WHERE has NO DocumentationPage branch ON PURPOSE —
  # external docs are out of global-search scope in v1. This pins that a doc-page
  # fragment is never returned here, even though the shared JOIN now reaches its row
  # (a regression signal if someone later widens the WHERE or the JOIN leaks docs in).
  describe 'documentation-page fragments stay out of the global search' do
    it 'never returns a documentation-page fragment even for a user with access to its project' do
      grant_access(user, project_a)
      set = create(:documentation_set, project: project_a, organisation: organisation)
      page = create(:documentation_page, documentation_set: set, organisation: organisation)
      doc_fragment = create(:fragment, fragmentable: page, organisation: organisation,
                                       plain_text_content: 'zebradiscovery doku content')

      results = run

      expect(results).not_to include(doc_fragment)
    end
  end
end

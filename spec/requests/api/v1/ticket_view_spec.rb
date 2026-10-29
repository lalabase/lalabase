# frozen_string_literal: true

require 'rails_helper'

# REST R1: the ticket view without MCP. The status list on the ticket list,
# opt-in pages of comments and attachments on GET /tickets/:id, one comment by
# id and the ticket by its number. Pages come from Tickets::Reading, the same
# service the MCP get_ticket tool uses, so REST is compared against MCP here.
#
# Rights: only comments the reader may read are listed, counted or served one
# by one. A hidden comment, a foreign one and a missing one answer the same
# 404; so do a missing number, a number in a project beyond the token's reach
# or the reader's access, an unreadable ticket and another organisation.
RSpec.describe 'REST ticket view', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:not_found_body) { { error: 'not_found', code: 'not_found' }.to_json }

  def member(role_for = role, tickets: 'read_only', on: project)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        user = create(:user)
        create(:membership, user: user, organisation: organisation, role: role_for, active: true)
        create(:project_permission, user: user, project: on, tickets_access: tickets) if tickets
        user
      end
    end
  end

  let(:author) { member }
  let(:addressee) { member }
  let(:other) { member }
  let(:admin_role) { Prosopite.pause { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } } }
  let(:admin) { member(admin_role, tickets: nil) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: author) }
  let(:long_text) { "#{'Lang ' * 2_000}Ende" }

  # Seven comments, two of them private for the addressee, in a fixed order; the
  # first public one is longer than MCP's 8,000-character cap.
  let!(:posts) do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        Projects::DefaultAttributeService.new(project).call
        base = 2.hours.ago
        Array.new(7) do |i|
          private_one = [2, 5].include?(i)
          create(:post, ticket: ticket, organisation: organisation, user: author,
                        content: i.zero? ? long_text : "Kommentar #{i}",
                        is_private: private_one, visible_to_user: (addressee if private_one),
                        create_embeddings: false, created_at: base + i.minutes)
        end
      end
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def token_for(user, **options)
    Prosopite.pause do
      create(:personal_access_token, user: user, organisations: [organisation], **options).token
    end
  end

  def get_json(user, path, params = {}, token: nil)
    get path, params: params, headers: { 'Authorization' => "Bearer #{token || token_for(user)}" }
    response.parsed_body
  end

  def ticket_path(id = ticket.id) = "/api/v1/tickets/#{id}"
  def number_path(number, project_id: project.id) = "/api/v1/projects/#{project_id}/tickets/number/#{number}"

  def mcp_answer(user, tool, **args)
    ActsAsTenant.with_tenant(organisation) do
      context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project)
      JSON.parse(Lalabase::Tools.const_get(tool).execute(args: args, context: context).content)
    end
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq(not_found_body)
  end

  let(:page_keys) do
    %w[posts posts_total posts_truncated posts_page posts_per_page posts_pages posts_order
       attachments attachments_total attachments_truncated attachments_page attachments_pages]
  end

  describe 'GET /projects/:project_id/tickets meta.available_statuses' do
    it 'lists the statuses MCP list_tickets names for the same project' do
      body = get_json(other, "/api/v1/projects/#{project.id}/tickets")
      expected = mcp_answer(other, :ListTickets).dig('meta', 'available_statuses')
      expect(expected).to be_present
      expect(body.dig('meta', 'available_statuses')).to eq(expected)
      expect(body['meta'].keys).to eq(%w[page per_page total available_statuses])
    end
  end

  describe 'GET /tickets/:id without paging parameters' do
    it 'keeps the body it always had: the whole ticket with every readable comment, uncut' do
      body = get_json(other, ticket_path)
      expected = Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          Tickets::Serializer.new(current_user: other).full(Ticket.find(ticket.id)).as_json
        end
      end
      expect(body.keys).to eq(%w[data permissions])
      expect(body['data']).to eq(expected)
      expect(body['data'].keys).not_to include(*page_keys.excluding('posts'))
      expect(body.dig('data', 'posts', 0, 'body_text')).to eq(long_text)
    end
  end

  describe 'GET /tickets/:id with paging parameters' do
    # One example per reader: Prosopite watches each request on its own.
    { other: 5, addressee: 7, admin: 7 }.each do |reader, total|
      it "pages and counts what the #{reader} may read, like MCP get_ticket" do
        user = public_send(reader)
        body = get_json(user, ticket_path, { posts_per_page: '3', posts_order: 'newest' })
        mcp = mcp_answer(user, :GetTicket, ticket_id: ticket.id, posts_per_page: 3, posts_order: 'newest')

        expect(response).to have_http_status(:ok)
        expect(body['data']['posts_total']).to eq(total)
        expect(body['data'].slice(*page_keys)).to eq(mcp.slice(*page_keys))
        expect(body.keys).to eq(%w[data permissions])
      end
    end

    it 'hands out a whole comment where MCP cuts it' do
      body = get_json(other, ticket_path, { posts_page: 1 })
      expect(body.dig('data', 'posts', 0, 'body_text')).to eq(long_text)
      expect(mcp_answer(other, :GetTicket, ticket_id: ticket.id).dig('posts', 0, 'body_text').length)
        .to be < long_text.length
    end

    it 'turns the pages without skipping or repeating a readable comment' do
      first = get_json(other, ticket_path, { posts_per_page: 3, posts_page: 1 }).dig('data', 'posts')
      second = get_json(other, ticket_path, { posts_per_page: 3, posts_page: 2 }).dig('data', 'posts')
      expected = posts.reject(&:is_private?).map(&:id)
      expect((first + second).pluck('id')).to eq(expected)
    end

    it 'answers a page past the end with no comments and the true totals' do
      body = get_json(other, ticket_path, { posts_page: 9, posts_per_page: 2 })['data']
      expect(body.slice('posts', 'posts_total', 'posts_pages', 'posts_truncated', 'posts_page'))
        .to eq('posts' => [], 'posts_total' => 5, 'posts_pages' => 3, 'posts_truncated' => true, 'posts_page' => 9)
      mcp = mcp_answer(other, :GetTicket, ticket_id: ticket.id, posts_page: 9, posts_per_page: 2)
      expect(body.slice(*page_keys)).to eq(mcp.slice(*page_keys))
    end

    # One example per option: Prosopite reads one call site asked four times as an N+1.
    { 'posts_page' => '1', 'posts_per_page' => '1', 'posts_order' => 'oldest', 'attachments_page' => '1' }.each do |key, value|
      it "switches to pages with #{key} alone" do
        body = get_json(other, ticket_path, { key => value })
        expect(body['data'].keys).to include(*page_keys)
      end
    end

    let(:other_token) { token_for(other) }

    { { posts_per_page: '51' } => 'posts_per_page', { posts_page: '0' } => 'posts_page',
      { posts_order: 'random' } => 'posts_order', { attachments_page: 'x' } => 'attachments_page',
      { posts_page: ['1'] } => 'posts_page' }.each do |params, name|
      it "refuses #{params.inspect} with 422 invalid_input" do
        body = get_json(other, ticket_path, params)
        expect(response).to have_http_status(:unprocessable_content)
        expect(body.slice('error', 'code')).to eq('error' => 'invalid_input', 'code' => 'invalid_input')
        expect(body['message']).to include(name)
      end
    end

    it 'refuses an invalid option the same way whether the ticket exists or not' do
      get_json(other, ticket_path(SecureRandom.uuid), { posts_order: 'random' }, token: other_token)
      missing = [response.status, response.body]
      get_json(other, ticket_path, { posts_order: 'random' }, token: other_token)
      expect([response.status, response.body]).to eq(missing)
    end

    context 'with attachments' do
      let!(:files) do
        Prosopite.pause do
          ActsAsTenant.with_tenant(organisation) do
            # A file on a private comment the reader cannot see: never in the list.
            hidden = PostDocument.new(post: posts[2], organisation: organisation, create_embeddings: false)
            hidden.post_document_file.attach(io: StringIO.new('Geheim'), filename: 'geheim.txt',
                                             content_type: 'text/plain', identify: false)
            hidden.save!
            Array.new(11) do
              document = TicketDocument.new(ticket: ticket, organisation: organisation, create_embeddings: false)
              document.ticket_document_file.attach(io: StringIO.new('Inhalt'), filename: 'notiz.txt',
                                                   content_type: 'text/plain', identify: false)
              document.save!
              document
            end
          end
        end
      end

      it 'pages the ticket files like MCP, never a file of a comment' do
        body = get_json(other, ticket_path, { attachments_page: 2 })['data']
        mcp = mcp_answer(other, :GetTicket, ticket_id: ticket.id, attachments_page: 2)
        attachment_keys = page_keys.grep(/\Aattachments/)
        expect(body.slice(*attachment_keys)).to eq(mcp.slice(*attachment_keys))
        expect(body.slice('attachments_total', 'attachments_pages', 'attachments_page'))
          .to eq('attachments_total' => 11, 'attachments_pages' => 2, 'attachments_page' => 2)
        expect(body['attachments'].size).to eq(1)
        expect(response.body).not_to include('geheim.txt')
      end
    end
  end

  describe 'GET /tickets/:ticket_id/posts/:id' do
    def post_path(post_id, ticket_id: ticket.id) = "/api/v1/tickets/#{ticket_id}/posts/#{post_id}"

    let(:private_post) { posts[2] }

    it 'serves one readable comment whole, as the ticket lists it' do
      body = get_json(other, post_path(posts[0].id))
      listed = get_json(other, ticket_path).dig('data', 'posts', 0)
      expect(response).to have_http_status(:ok)
      expect(body).to eq('data' => listed)
      expect(body.dig('data', 'body_text')).to eq(long_text)
    end

    it 'serves a private comment to its addressee' do
      body = get_json(addressee, post_path(private_post.id))
      expect(body.dig('data', 'id')).to eq(private_post.id)
    end

    it 'serves a private comment to an account admin' do
      expect(get_json(admin, post_path(private_post.id)).dig('data', 'id')).to eq(private_post.id)
    end

    it 'hides a private comment from another member like a missing one' do
      get_json(other, post_path(private_post.id))
      expect_not_found
    end

    it 'answers a missing and a malformed comment id the same way' do
      get_json(other, post_path(SecureRandom.uuid))
      expect_not_found
      get_json(other, post_path('abc'))
      expect_not_found
    end

    it 'does not serve a comment through another ticket' do
      sibling = Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, creator: author) }
      end
      get_json(other, post_path(posts[1].id, ticket_id: sibling.id))
      expect_not_found
    end

    it 'does not serve a comment of a ticket the reader may not read' do
      outsider = member(tickets: nil)
      get_json(outsider, post_path(posts[1].id))
      expect_not_found
    end
  end

  describe 'GET /projects/:project_id/tickets/number/:number' do
    it 'answers exactly what GET /tickets/:id answers for the same ticket' do
      token = token_for(other)
      by_id = get_json(other, ticket_path, {}, token: token)
      expect(get_json(other, number_path(ticket.number), {}, token: token)).to eq(by_id)
      expect(response).to have_http_status(:ok)
    end

    it 'takes the paging parameters too' do
      token = token_for(addressee)
      params = { posts_per_page: 2, posts_order: 'newest' }
      by_id = get_json(addressee, ticket_path, params, token: token)
      expect(get_json(addressee, number_path(ticket.number), params, token: token)).to eq(by_id)
      expect(by_id.dig('data', 'posts_total')).to eq(7)
      get_json(addressee, number_path(ticket.number), { posts_per_page: 51 }, token: token)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'never answers with the ticket of the same number in another project' do
      sibling_project, sibling = Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          other_project = create(:project, organisation: organisation)
          create(:project_permission, user: other, project: other_project, tickets_access: 'read_only')
          tickets = Array.new(2) { create(:ticket, project: other_project, organisation: organisation, creator: author) }
          [other_project, tickets.last]
        end
      end
      token = token_for(other)
      expect(get_json(other, number_path(1, project_id: sibling_project.id), {}, token: token).dig('data', 'id'))
        .not_to eq(ticket.id)
      expect(get_json(other, number_path(ticket.number), {}, token: token).dig('data', 'id')).to eq(ticket.id)
      get_json(other, number_path(sibling.number), {}, token: token)
      expect_not_found
    end

    it 'answers an unknown number with the not-found body' do
      get_json(other, number_path(ticket.number + 1))
      expect_not_found
    end

    %w[abc 0 -1 1.5].each do |raw|
      it "answers the malformed number #{raw.inspect} like a missing one" do
        get_json(other, number_path(raw))
        expect_not_found
      end
    end

    it 'answers an unknown project like a missing number' do
      get_json(other, number_path(ticket.number, project_id: SecureRandom.uuid))
      expect_not_found
    end

    it 'hides a project beyond the token reach, even from an account admin' do
      elsewhere = Prosopite.pause { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
      token = token_for(admin, project_scopes: { organisation => [elsewhere] })
      get_json(admin, number_path(ticket.number), {}, token: token)
      expect_not_found
    end

    it 'hides the ticket from a member without access to its project' do
      outsider = member(tickets: nil)
      get_json(outsider, number_path(ticket.number))
      expect_not_found
    end

    it 'hides the ticket from a member who may read only the notes of its project' do
      notes_only = member(tickets: 'no_access')
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          notes_only.project_permissions.find_by!(project: project).update!(notes_access: 'read_only')
        end
      end
      get_json(notes_only, number_path(ticket.number))
      expect_not_found
    end

    it 'hides a ticket of another organisation' do
      foreign = Prosopite.pause do
        org = create(:organisation)
        ActsAsTenant.with_tenant(org) do
          create(:ticket, organisation: org, project: create(:project, organisation: org), creator: create(:user))
        end
      end
      get_json(other, number_path(foreign.number, project_id: foreign.project_id))
      expect_not_found
    end

    it 'refuses invalid paging before it looks the number up' do
      token = token_for(other)
      get_json(other, number_path(999), { posts_order: 'random' }, token: token)
      missing = [response.status, response.body]
      get_json(other, number_path(ticket.number), { posts_order: 'random' }, token: token)
      expect([response.status, response.body]).to eq(missing)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# REST R7: a comment hands out its files wherever a comment is served, on REST and
# on MCP. One payload (Tickets::Serializer#post_payload), and every road to it is
# walked here, so a road that loses the preload or builds its own shape turns red.
#
# The list answers three questions the terminal client builds on. Which file: `id`
# is the PostDocument's, the id the file proxy takes, not the Active Storage
# attachment's that GET /tickets/:id/attachments hands out. What it says about the
# file: name, type and size, never a signed link or the extracted text. Who sees
# it: whoever may read the comment (Post.readable_by), by no second rule.
RSpec.describe 'Comment files in the ticket view', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }

  def member(role_for = role, tickets: 'read_only')
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        user = create(:user)
        create(:membership, user: user, organisation: organisation, role: role_for, active: true)
        create(:project_permission, user: user, project: project, tickets_access: tickets) if tickets
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

  def comment(minute, **attributes)
    create(:post, ticket: ticket, organisation: organisation, user: author, content: "Kommentar #{minute}",
                  create_embeddings: false, created_at: 2.hours.ago + minute.minutes, **attributes)
  end

  def file(on, filename, content_type, id: nil)
    document = PostDocument.new(id: id, post: on, organisation: organisation, create_embeddings: false)
    document.post_document_file.attach(io: StringIO.new('Inhalt'), filename: filename,
                                       content_type: content_type, identify: false)
    document.save!
    document
  end

  # The file with the higher id is made first and has the earlier name: the list
  # follows the id, not the order the rows were written in, nor the name.
  let(:higher_id) { 'ffffffff-ffff-4fff-8fff-ffffffffffff' }
  let(:lower_id) { '00000000-0000-4000-8000-00000000000a' }

  # In order: two files, a private comment with one, no file, one file.
  let!(:comments) do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        with_files = comment(0)
        file(with_files, 'bericht.pdf', 'application/pdf', id: higher_id)
        file(with_files, 'screenshot.png', 'image/png', id: lower_id)
        hidden = comment(1, is_private: true, visible_to_user: addressee)
        file(hidden, 'geheim.txt', 'text/plain')
        empty = comment(2)
        last = comment(3)
        file(last, 'protokoll.txt', 'text/plain')
        { with_files: with_files, hidden: hidden, empty: empty, last: last }
      end
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def token_for(user)
    Prosopite.pause { create(:personal_access_token, user: user, organisations: [organisation]).token }
  end

  def get_json(user, path, params = {})
    get path, params: params, headers: { 'Authorization' => "Bearer #{token_for(user)}" }
    response.parsed_body
  end

  # Through the whole MCP road: dispatcher, token, tool. The tool's answer is JSON
  # in a text field.
  def mcp_ticket(user, **arguments)
    post '/api/mcp',
         params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                   params: { name: 'get_ticket', arguments: { project_id: project.id, ticket_id: ticket.id, **arguments } } }.to_json,
         headers: { 'Authorization' => "Bearer #{token_for(user)}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    response.parsed_body.dig('result', 'content', 0, 'text')
  end

  def ticket_path = "/api/v1/tickets/#{ticket.id}"
  def number_path = "/api/v1/projects/#{project.id}/tickets/number/#{ticket.number}"
  def comment_path(key) = "#{ticket_path}/posts/#{comments.fetch(key).id}"

  def listed_on(posts, key)
    posts.find { |entry| entry['id'] == comments.fetch(key).id }&.fetch('attachments')
  end

  def filenames(posts)
    posts.flat_map { |entry| entry['attachments'].pluck('filename') }
  end

  def proxy_get(id)
    get organisation_file_download_path(organisation_id: organisation.id, kind: 'post_document', id: id)
  end

  let(:both_files) do
    [{ 'id' => lower_id, 'filename' => 'screenshot.png', 'content_type' => 'image/png', 'byte_size' => 6 },
     { 'id' => higher_id, 'filename' => 'bericht.pdf', 'content_type' => 'application/pdf', 'byte_size' => 6 }]
  end

  describe 'on every road to a comment' do
    it 'lists them on the whole ticket, in id order, with nothing but these four fields' do
      posts = get_json(other, ticket_path).dig('data', 'posts')
      expect(listed_on(posts, :with_files)).to eq(both_files)
    end

    it 'lists them on a page of the ticket' do
      posts = get_json(other, ticket_path, { posts_per_page: 1 }).dig('data', 'posts')
      expect(listed_on(posts, :with_files)).to eq(both_files)
    end

    it 'lists them on the ticket by number' do
      posts = get_json(other, number_path).dig('data', 'posts')
      expect(listed_on(posts, :with_files)).to eq(both_files)
    end

    it 'lists them on a page of the ticket by number' do
      posts = get_json(other, number_path, { posts_order: 'newest', posts_per_page: 3 }).dig('data', 'posts')
      expect(listed_on(posts, :with_files)).to eq(both_files)
    end

    it 'lists them on one comment' do
      expect(get_json(other, comment_path(:with_files)).dig('data', 'attachments')).to eq(both_files)
    end

    it 'lists them on MCP get_ticket' do
      expect(listed_on(JSON.parse(mcp_ticket(other))['posts'], :with_files)).to eq(both_files)
    end

    it 'lists them on one comment of MCP get_ticket' do
      answer = JSON.parse(mcp_ticket(other, post_id: comments[:with_files].id))
      expect(listed_on(answer['posts'], :with_files)).to eq(both_files)
    end

    it 'answers an empty list for a comment without files, beside its count' do
      body = get_json(other, comment_path(:empty))
      expect(body['data'].slice('attachments', 'attachments_count')).to eq('attachments' => [], 'attachments_count' => 0)
    end

    it 'keeps the ticket files apart: a page of them holds no file of a comment' do
      body = get_json(other, ticket_path, { attachments_page: 1 })['data']
      expect(body['attachments']).to eq([])
      expect(listed_on(body['posts'], :with_files)).to eq(both_files)
    end
  end

  describe 'the id' do
    it 'opens the file through the proxy, for the person who read the list' do
      id = get_json(other, comment_path(:with_files)).dig('data', 'attachments', 0, 'id')
      sign_in other
      proxy_get(id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('Inhalt')
    end

    it 'is not the id the attachments route hands out' do
      token = token_for(other)
      get "#{ticket_path}/attachments", headers: { 'Authorization' => "Bearer #{token}" }
      routed = response.parsed_body['data'].find { |entry| entry['filename'] == 'bericht.pdf' }
      expect(routed['id']).not_to eq(higher_id)
      sign_in other
      proxy_get(routed['id'])
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'a file of a private comment' do
    let(:hidden_file) { ActsAsTenant.with_tenant(organisation) { comments[:hidden].post_documents.first } }

    # One example per reader: Prosopite watches each request on its own.
    %i[author addressee admin].each do |reader|
      it "is listed for the #{reader}, with the comment" do
        posts = get_json(public_send(reader), ticket_path).dig('data', 'posts')
        expect(listed_on(posts, :hidden).pluck('filename')).to eq(['geheim.txt'])
      end

      it "opens through the proxy for the #{reader}" do
        sign_in public_send(reader)
        proxy_get(hidden_file.id)
        expect(response).to have_http_status(:ok)
      end
    end

    # Each list is shown to be there, with the public files on it, so an absent
    # name means the filter worked and not that the answer was empty.
    context 'for a member who may not read the comment' do
      let(:public_names) { %w[screenshot.png bericht.pdf protokoll.txt] }

      it 'is missing from the whole ticket' do
        posts = get_json(other, ticket_path).dig('data', 'posts')
        expect(filenames(posts)).to eq(public_names)
        expect(response.body).not_to include('geheim.txt')
      end

      it 'is missing from a page, and from its count' do
        data = get_json(other, ticket_path, { posts_page: 1 })['data']
        expect(filenames(data['posts'])).to eq(public_names)
        expect(data['posts_total']).to eq(3)
        expect(response.body).not_to include('geheim.txt')
      end

      it 'is missing from the ticket by number' do
        posts = get_json(other, number_path).dig('data', 'posts')
        expect(filenames(posts)).to eq(public_names)
        expect(response.body).not_to include('geheim.txt')
      end

      it 'is missing from MCP get_ticket' do
        answer = mcp_ticket(other)
        expect(filenames(JSON.parse(answer)['posts'])).to eq(public_names)
        expect(answer).not_to include('geheim.txt')
      end

      it 'answers its comment as not found' do
        get_json(other, comment_path(:hidden))
        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include('geheim.txt')
      end

      it 'answers its comment on MCP as not found' do
        expect(mcp_ticket(other, post_id: comments[:hidden].id)).to start_with('No comment found')
        expect(response.body).not_to include('geheim.txt')
      end

      it 'does not open through the proxy, known id or not' do
        sign_in other
        proxy_get(hidden_file.id)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'a document that lost its blob' do
    before do
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          ActiveStorage::Attachment.where(record_type: 'PostDocument', record_id: higher_id).delete_all
        end
      end
    end

    it 'is dropped from the list and stays in the count' do
      data = get_json(other, comment_path(:with_files))['data']
      expect(data['attachments']).to eq(both_files.first(1))
      expect(data['attachments_count']).to eq(2)
    end

    it 'is dropped from the list of MCP get_ticket and stays in the count' do
      entry = JSON.parse(mcp_ticket(other))['posts'].first
      expect(entry['attachments']).to eq(both_files.first(1))
      expect(entry['attachments_count']).to eq(2)
    end
  end

  # Prosopite watches every example here, and four files on three comments are
  # enough for it to speak. This one says what it would only imply: one read of
  # each table for a whole page.
  describe 'the reads behind the list' do
    def sql_during(&)
      statements = []
      counter = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      statements
    end

    it 'read the attachment rows and the blobs once for a page of comments' do
      token = token_for(admin)
      statements = sql_during do
        get ticket_path, params: { posts_page: 1 }, headers: { 'Authorization' => "Bearer #{token}" }
      end
      expect(response.parsed_body.dig('data', 'posts').sum { |entry| entry['attachments'].size }).to eq(4)
      expect(statements.grep(/FROM "active_storage_attachments"/).size).to eq(1)
      expect(statements.grep(/FROM "active_storage_blobs"/).size).to eq(1)
    end
  end
end

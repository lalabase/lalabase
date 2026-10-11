# frozen_string_literal: true

require 'rails_helper'

# Escaping is an injection boundary: text must survive both ActionText storage
# and the comment component, with the existing token, ticket and post policies.
RSpec.describe 'MCP plain comments', :ci_guard, type: :request do
  include ViewComponent::TestHelpers

  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user)
    end
  end
  let(:read_only) { false }
  let(:pat) do
    build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only).tap do |token|
      token.token_hash = nil
      token.token_prefix = nil
      token.generate_token!
    end
  end

  def call_tool(arguments = {})
    args = { project_id: project.id, ticket_id: ticket.id, format: 'plain', body: "line one\nline two" }.merge(arguments)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: 'post_comment', arguments: args } }.to_json,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch('result')
  end

  def stored_post(result)
    ActsAsTenant.with_tenant(organisation) { Post.find(JSON.parse(result.dig('content', 0, 'text')).fetch('id')) }
  end

  def post_count
    ActsAsTenant.without_tenant { Post.count }
  end

  samples = {
    'line breaks' => "line one\nline two",
    'operators' => 'a < b && c > d',
    'markup' => "<b>bold</b> <script>#{0x2026.chr(Encoding::UTF_8)}</script>",
    'entities' => 'literal &lt;tag&gt;',
    'code' => "if ready\n  puts \"<hi>\"\nend",
    'file names' => 'see <file.txt>'
  }

  samples.each do |label, body|
    it "round trips #{label} as text, with no injected elements" do
      result = call_tool(body: body)
      expect(result['_meta']).to eq('lalabase/kind' => 'ok')
      expect(JSON.parse(result.dig('content', 0, 'text')).fetch('body_text')).to eq(body)
      saved = stored_post(result)
      ActsAsTenant.with_tenant(organisation) do
        expect(saved.plain_text_version).to eq(body)
        fragment = Nokogiri::HTML.fragment(saved.content.body.to_html)
        expect(fragment.css('*').map(&:name).uniq - %w[p br]).to be_empty
        expect(fragment.css('p').size).to eq(1)
        expect(fragment.css('br').size).to eq(body.count("\n"))
      end
    end
  end

  it 'renders paragraphs and line breaks in NeoPostComponent after CRLF normalization' do
    result = call_tool(body: "\r\n\r\na\r\nb\r\n\r\n\r\nc\r\n\r\n")
    saved = stored_post(result)
    expect(saved.plain_text_version).to eq("a\nb\n\nc")
    ActsAsTenant.with_tenant(organisation) do
      render_inline(NeoPostComponent.new(post: saved, current_user: user, current_organisation: organisation,
                                         show_edit_button: false, turbo_frame: false))
      fragment = Nokogiri::HTML.fragment(rendered_content)
      expect(fragment.css('.lexxy-content p').map(&:inner_html)).to eq(['a<br>b', 'c'])
    end
  end

  it 'keeps a private plain comment addressed to its author' do
    result = call_tool(is_private: true, body: '<private>')
    saved = stored_post(result)
    expect(JSON.parse(result.dig('content', 0, 'text'))).to include('is_private' => true, 'body_text' => '<private>')
    expect(saved).to be_private
    expect(saved.visible_to_user_id).to eq(user.id)
    ActsAsTenant.with_tenant(organisation) do
      expect(Post.readable_by(create(:user), organisation)).not_to include(saved)
    end
  end

  it 'renders literal markup as text in NeoPostComponent' do
    saved = stored_post(call_tool(body: samples.fetch('markup')))
    ActsAsTenant.with_tenant(organisation) do
      render_inline(NeoPostComponent.new(post: saved, current_user: user, current_organisation: organisation,
                                         show_edit_button: false, turbo_frame: false))
      fragment = Nokogiri::HTML.fragment(rendered_content)
      expect(fragment.css('.lexxy-content').text).to include('<b>bold</b>', '<script>')
      expect(fragment.css('.lexxy-content script, .lexxy-content b')).to be_empty
    end
  end

  it 'rejects a plain body of only Unicode whitespace as invalid_input without writing' do
    result = nil
    expect { result = call_tool(body: 0xA0.chr(Encoding::UTF_8)) }.not_to(change { post_count })
    expect(result['_meta']).to eq('lalabase/code' => 'invalid_input')
    expect(result.dig('content', 0, 'text')).to eq('body is required')
  end

  context 'with a read-only token' do
    let(:read_only) { true }

    it 'returns read_only without writing' do
      result = nil
      expect { result = call_tool }.not_to(change { post_count })
      expect(result['_meta']).to eq('lalabase/code' => 'read_only')
    end
  end

  %w[unreadable missing].each do |kind|
    it "answers an #{kind} ticket with the same empty result without writing" do
      ActsAsTenant.with_tenant(organisation) { permission.update!(tickets_access: :no_access, notes_access: :read_only) }
      address = kind == 'unreadable' ? ticket.id : SecureRandom.uuid
      result = nil
      expect { result = call_tool(ticket_id: address) }.not_to(change { post_count })
      expect(result).to eq('content' => [{ 'type' => 'text', 'text' => "No ticket found for #{address}." }],
                           'isError' => false, '_meta' => { 'lalabase/kind' => 'empty' })
    end
  end

  it 'answers a project of another organisation like a missing one without writing' do
    foreign = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    foreign_ticket = ActsAsTenant.with_tenant(other_organisation) do
      create(:ticket, project: foreign, organisation: other_organisation, creator: create(:user))
    end
    result = missing = nil
    expect do
      result = call_tool(project_id: foreign.id, ticket_id: foreign_ticket.id)
      missing = call_tool(project_id: SecureRandom.uuid, ticket_id: foreign_ticket.id)
    end.not_to(change { post_count })
    expect(result['_meta']).to eq('lalabase/code' => 'not_found')
    expect(result).to eq(missing)
  end

  it 'answers a ticket of another organisation under the own project as empty without writing' do
    foreign = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    foreign_ticket = ActsAsTenant.with_tenant(other_organisation) do
      create(:ticket, project: foreign, organisation: other_organisation, creator: create(:user))
    end
    result = nil
    expect { result = call_tool(ticket_id: foreign_ticket.id) }.not_to(change { post_count })
    expect(result).to eq('content' => [{ 'type' => 'text', 'text' => "No ticket found for #{foreign_ticket.id}." }],
                         'isError' => false, '_meta' => { 'lalabase/kind' => 'empty' })
  end

  it 'returns forbidden for a readable ticket without write access' do
    ActsAsTenant.with_tenant(organisation) { permission.update!(tickets_access: :read_only) }
    result = nil
    expect { result = call_tool }.not_to(change { post_count })
    expect(result['_meta']).to eq('lalabase/code' => 'forbidden')
  end

  it 'keeps a model refusal as refused with the existing message' do
    allow_any_instance_of(Post).to receive(:save!) do |record|
      record.errors.add(:content, :blank)
      raise ActiveRecord::RecordInvalid, record
    end
    result = nil
    expect { result = call_tool }.not_to(change { post_count })
    expect(result['_meta']).to eq('lalabase/code' => 'refused')
    expect(result.dig('content', 0, 'text')).to start_with('comment failed:')
  end
end

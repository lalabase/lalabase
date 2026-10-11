# frozen_string_literal: true

require 'rails_helper'

# Full-text reads have a smaller allowance in the chat. These are source-field
# limits, not a bound on a whole result: ordinary comment pages remain unchanged.
# Literal sizes keep a changed constant from silently changing the expectations.
RSpec.describe Lalabase::Tools::GetTicket, 'assistant full-text limits', :ci_guard do
  let(:organisation) { create(:organisation, :ai_disabled) }
  let(:project) { create(:project, organisation: organisation, name: 'Probe') }
  let(:actor) { create(:user, first_name: 'Probe', last_name: 'Reader') }
  let(:chat) { create(:chat, organisation: organisation, user: actor, language: 'en') }
  let(:description_source) { "<p>#{'Description ä ' * 8_000}</p>" }
  let(:comment_source) { "<p>#{'Comment ö ' * 11_000}</p>" }
  let(:ticket) do
    create(:ticket, organisation: organisation, project: project, creator: actor,
                    title: 'Probe', content: description_source)
  end
  let(:comment) do
    create(:post, organisation: organisation, ticket: ticket, user: actor,
                  content: comment_source, create_embeddings: false)
  end
  let(:context) do
    Lalabase::Tools::Context.new(chat: chat, organisation: organisation, actor: actor,
                                 scope: Lalabase::Tools::Scope.for(chat: chat, actor: actor))
  end
  let(:marker) { "\n\n…[truncated]" }

  before do
    # Factories save several independent records. Only setup is outside the scan;
    # every example executes exactly one tool call under Prosopite.
    Prosopite.pause do
      ActsAsTenant.current_tenant = organisation
      role = create(:role, organisation: organisation)
      create(:membership, user: actor, organisation: organisation, role: role, active: true)
      create(:project_permission, user: actor, project: project, tickets_access: 'read_only')
      ticket
      comment
      chat
      @source = {
        'description_html' => ticket.content.body.to_html,
        'description_text' => ticket.content.body.to_plain_text,
        'body_html' => comment.content.body.to_html,
        'body_text' => comment.plain_text_version
      }
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def execute(**args)
    described_class.execute(args: { ticket_id: ticket.id }.merge(args), context: context)
  end

  def payload(result)
    expect(result).to be_success
    JSON.parse(result.content)
  end

  def expect_description(body, limit)
    %w[description_html description_text].each do |field|
      expect(body.fetch(field)).to eq(@source.fetch(field)[0, limit] + marker)
      expect(body.fetch(field).length).to eq(limit + 14)
    end
  end

  def expect_comment(body, limit)
    expect(body.fetch('posts').pluck('id')).to eq([comment.id])
    %w[body_html body_text].each do |field|
      expect(body.fetch('posts').sole.fetch(field)).to eq(@source.fetch(field)[0, limit] + marker)
      expect(body.fetch('posts').sole.fetch(field).length).to eq(limit + 14)
    end
  end

  describe '1: full description' do
    it 'returns exactly 16000 source characters in both description fields' do
      body = payload(execute(full_text: true))
      expect_description(body, 16_000)
      expect_comment(body, 8_000)
    end
  end

  describe '2: one comment' do
    it 'returns exactly 16000 source characters in both comment fields only' do
      body = payload(execute(post_id: comment.id))
      expect_comment(body, 16_000)
      expect_description(body, 8_000)
    end
  end

  describe '3: both options' do
    it 'bounds all four fields and retains the selected comment provenance' do
      result = execute(full_text: true, post_id: comment.id)
      body = payload(result)
      expect_description(body, 16_000)
      expect_comment(body, 16_000)
      expect(result.citations.sole[:post_ids]).to eq([comment.id])
      expect(body).to include('post_id' => comment.id, 'posts_total' => 1, 'posts_truncated' => false)
    end
  end

  describe '4: character boundaries' do
    %w[description_html description_text body_html body_text].each do |field|
      [15_999, 16_000, 16_001].each do |size|
        context "with #{size} characters in #{field}" do
          # The HTML wrapper contributes seven characters. Plain text does not.
          let(:source) { "<p>#{'ä' * (field.end_with?('_html') ? size - 7 : size)}</p>" }
          let(:description_source) { source }
          let(:comment_source) { source }

          it 'keeps the exact prefix and marks only an actual cut' do
            expect(@source.fetch(field).length).to eq(size)
            body = payload(execute(full_text: true, post_id: comment.id))
            actual = field.start_with?('description') ? body.fetch(field) : body.fetch('posts').sole.fetch(field)
            expected = size > 16_000 ? @source.fetch(field)[0, 16_000] + marker : @source.fetch(field)
            expect(actual).to eq(expected)
            expect(actual).to be_valid_encoding
          end
        end
      end
    end
  end

  describe '5: values that need no cut' do
    context 'with short text' do
      let(:description_source) { 'short ä' }
      let(:comment_source) { 'short ä' }

      it 'preserves both representations without a marker' do
        body = payload(execute(full_text: true, post_id: comment.id))
        expect(body.slice('description_html', 'description_text')).to eq(@source.slice('description_html', 'description_text'))
        expect(body.fetch('posts').sole.slice('body_html', 'body_text')).to eq(@source.slice('body_html', 'body_text'))
      end
    end

    [nil, ''].each do |value|
      it "preserves #{value.inspect} fields supplied by the serializer" do
        serializer = Tickets::Serializer.new(current_user: actor)
        allow(Tickets::Serializer).to receive(:new).with(current_user: actor).and_return(serializer)
        allow(serializer).to receive(:full).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs).merge(description_html: value, description_text: value)
        end
        allow(serializer).to receive(:readable_post).and_wrap_original do |original, *args|
          original.call(*args).merge(body_html: value, body_text: value)
        end
        body = payload(execute(full_text: true, post_id: comment.id))
        expect(body.slice('description_html', 'description_text').values).to eq([value, value])
        expect(body.fetch('posts').sole.slice('body_html', 'body_text').values).to eq([value, value])
      end
    end
  end

  describe '6: ordinary reads' do
    %i[assistant mcp].each do |surface|
      context "for #{surface}" do
        let(:context) do
          Lalabase::Tools::Context.new(chat: (chat if surface == :assistant), organisation: organisation,
                                       actor: actor, project: project)
        end

        [{}, { full_text: false }, { full_text: nil }, { full_text: '' }].each do |args|
          it "keeps 8000 characters and paging for #{args.inspect}" do
            body = payload(execute(**args))
            expect_description(body, 8_000)
            expect_comment(body, 8_000)
            expect(body).to include('posts_page' => 1, 'posts_per_page' => 50, 'posts_order' => 'oldest',
                                    'posts_total' => 1, 'posts_pages' => 1, 'posts_truncated' => false)
          end
        end
      end
    end
  end

  describe '7: MCP compatibility' do
    it 'keeps 100000 in all four fields through the real MCP ToolCall' do
      token = Prosopite.pause do
        create(:personal_access_token, user: actor, organisations: [organisation])
      end
      response = Mcp::ToolCall.new(token: token, tool_class: described_class,
                                   args: { project_id: project.id, ticket_id: ticket.id,
                                           full_text: true, post_id: comment.id }).response
      wire = response.to_h.deep_stringify_keys
      expect(wire['isError']).not_to be(true)
      body = JSON.parse(wire.fetch('content').sole.fetch('text'))
      expect_description(body, 100_000)
      expect_comment(body, 100_000)
    end
  end

  describe '8: context selection' do
    it 'uses the chat even when a project is present' do
      context.project = project
      body = payload(execute(full_text: true, post_id: comment.id))
      expect_description(body, 16_000)
      expect_comment(body, 16_000)
    end

    it 'does not mistake an org scope without a chat for the assistant' do
      context.chat = nil
      body = payload(execute(full_text: true, post_id: comment.id))
      expect_description(body, 100_000)
      expect_comment(body, 100_000)
    end

    it 'does not take a full-text allowance from model arguments' do
      body = payload(execute(full_text: true, post_id: comment.id, full_text_limit: 100_000))
      expect_description(body, 16_000)
      expect_comment(body, 16_000)
    end
  end

  describe '9: Runner integration' do
    %i[assistant assistant_with_code].each do |tool_set|
      it "hands the limited JSON to the provider for #{tool_set}" do
        provider = instance_double(Lalabase::Llm::OpenAiProvider)
        request = { id: 'one', name: 'get_ticket', args: { ticket_id: ticket.id, full_text: true, post_id: comment.id } }
        received = nil
        allow(provider).to receive(:chat) do |messages:, **|
          if messages.any? { |message| message[:role] == 'tool' }
            received = messages.select { |message| message[:role] == 'tool' }.sole
            { content: 'Synthetic answer', tool_calls: nil }
          else
            { content: '', tool_calls: [request] }
          end
        end
        runner = Lalabase::Tools::Runner.new(chat: chat, provider: provider, messages: [],
                                             asker: actor, tool_set: tool_set)
        runner.call { |_| }
        expect(received).not_to have_key(:is_error)
        body = JSON.parse(received.fetch(:content))
        expect_description(body, 16_000)
        expect_comment(body, 16_000)
        expect(runner.citations.sole[:post_ids]).to eq([comment.id])
        expect(provider).to have_received(:chat).twice
      end
    end
  end

  describe '10: attachment contribution' do
    let(:description_source) { 'd' * 100_100 }
    let(:comment_source) { 'p' * 100_100 }

    it 'keeps ten 4000-character attachment prefixes within the controlled ASCII case' do
      files = Prosopite.pause do
        Array.new(10) do
          create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation,
                                              plain_text_version: 'a' * 4_100)
        end
      end
      result = execute(full_text: true, post_id: comment.id)
      body = payload(result)
      expect_description(body, 16_000)
      expect_comment(body, 16_000)
      expect(body.fetch('attachments').pluck('id')).to match_array(files.map(&:id))
      expect(body.fetch('attachments').pluck('text')).to eq(Array.new(10, 'a' * 4_000 + marker))
      # This fixture is bounded; uncapped metadata and escaping make this no
      # promise about arbitrary results, nor about ordinary comment pages.
      expect(Lalabase::FenceGuard.sanitize(result.content).length).to be < 120_000
    end
  end
end

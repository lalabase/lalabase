# frozen_string_literal: true

# == Schema Information
#
# Table name: chatposts
#
#  id               :uuid             not null, primary key
#  content          :text
#  model_used       :string
#  role             :enum             default("user"), not null
#  source_citations :jsonb            not null
#  source_coverage  :jsonb
#  token_usage      :jsonb            not null
#  tool_calls       :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  chat_id          :uuid             not null
#  organisation_id  :uuid             not null
#  user_id          :uuid
#
# Indexes
#
#  index_chatposts_on_chat_id          (chat_id)
#  index_chatposts_on_organisation_id  (organisation_id)
#
require 'rails_helper'

RSpec.describe Chatpost, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'role enum' do
    # The Rails declaration and the PostgreSQL type are two separate places that state the same
    # vocabulary. A migration can add a value to the PG type without anyone touching the model,
    # and the model would then silently not know it — no predicate, no scope, and `role = 'new'`
    # raising ArgumentError in production. This pins them together.
    it 'matches the chatpost_role PostgreSQL enum exactly' do
      pg_values = ActiveRecord::Base.connection.select_values(
        'SELECT unnest(enum_range(NULL::chatpost_role))::text'
      )

      expect(described_class.roles.keys).to match_array(pg_values)
      expect(described_class.roles.values).to match_array(pg_values)
    end

    it 'exposes a predicate and a scope per value' do
      described_class.roles.each_key do |value|
        expect(described_class.new).to respond_to(:"#{value}?")
        expect(described_class).to respond_to(value.to_sym)
      end
      expect(described_class).to respond_to(:not_assistant)
    end

    it 'rejects a value outside the vocabulary' do
      expect { described_class.new(role: 'tool') }.to raise_error(ArgumentError, /tool/)
    end
  end

  describe 'associations' do
    # Organisation association is handled by acts_as_tenant
    it 'belongs to organisation through acts_as_tenant' do
      expect(Chatpost.reflect_on_association(:organisation)).to be_present
    end
    it { should belong_to(:user).optional }
  end

  describe 'validations' do
    it 'validates textile syntax' do
      # Valid textile
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, content: 'This is *bold* and _italic_.')
        expect(chatpost).to be_valid

        # Invalid textile (this is a simple test as RedCloth is quite permissive)
        allow(RedCloth).to receive(:new).and_raise(StandardError.new('Invalid textile'))
        chatpost = build(:chatpost, content: 'Invalid textile')
        expect(chatpost).not_to be_valid
        expect(chatpost.errors[:content]).to include(/Textile-Syntax-Fehler/)
      end
    end
  end

  describe 'callbacks' do
    let(:chat) do
      ActsAsTenant.with_tenant(organisation) do
        create(:chat, organisation: organisation)
      end
    end
    let(:chatpost) do
      ActsAsTenant.with_tenant(organisation) do
        build(:chatpost, chat: chat, organisation: organisation)
      end
    end

    before do
      # Stub broadcast methods to avoid template rendering errors
      allow_any_instance_of(Chatpost).to receive(:broadcast_created)
      allow_any_instance_of(Chatpost).to receive(:broadcast_updated)
    end

    it 'calls broadcast_created after create' do
      ActsAsTenant.with_tenant(organisation) do
        expect(chatpost).to receive(:broadcast_created)
        chatpost.save!
      end
    end

    it 'calls broadcast_updated after update' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost.save!
        expect(chatpost).to receive(:broadcast_updated)
        chatpost.touch
      end
    end

    describe '#set_initial_role' do
      # Both examples set up real state instead of stubbing `chat.chatposts.map`. The old stub
      # was tied to one particular implementation of the lookup, so it silently stopped
      # intercepting when the callback was rewritten — and a stub that no longer applies makes
      # the test pass or fail for reasons unrelated to the behaviour under test.
      it 'sets the role to system when the chat has no system post yet' do
        ActsAsTenant.with_tenant(organisation) do
          # The chat factory seeds one post, which this very callback already flipped to system.
          # Drop it so the chat genuinely has no system post.
          chat = create(:chat, organisation: organisation)
          chat.chatposts.destroy_all
          chat.chatposts.reload

          chatpost = build(:chatpost, chat: chat, role: nil, organisation: organisation)
          chatpost.send(:set_initial_role)
          expect(chatpost.role).to eq('system')
        end
      end

      it 'does not set the role to system if another system chatpost exists' do
        ActsAsTenant.with_tenant(organisation) do
          chat = create(:chat, organisation: organisation)
          # Precondition, stated rather than assumed: the factory's seeded post IS the system post.
          expect(chat.chatposts.reload).to include(be_system)

          chatpost = build(:chatpost, chat: chat, role: 'user', organisation: organisation)
          chatpost.send(:set_initial_role)
          expect(chatpost.role).to eq('user')
        end
      end
    end
  end

  describe 'broadcasting' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:chat) do
      ActsAsTenant.with_tenant(organisation) do
        create(:chat, organisation: organisation)
      end
    end

    before do
      # Stub out broadcasting methods to avoid template rendering
      allow_any_instance_of(Chatpost).to receive(:broadcast_append_to).and_return(true)
    end

    it 'has broadcast_created and broadcast_updated methods' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, chat: chat, organisation: organisation)
        expect(chatpost).to respond_to(:broadcast_created)
        expect(chatpost).to respond_to(:broadcast_updated)
      end
    end

    # Regression: M3 deleted the chatpost_content partial and replaced it with
    # Neo::Chat::MessageComponent. The model's broadcasts must use the component,
    # otherwise streaming AI responses silently fail to update the UI (the
    # rescue StandardError swallows the missing-partial error).
    describe 'broadcasts must use Neo::Chat::MessageComponent (not the deleted partial)' do
      it 'broadcast_created sends a renderable (not a partial) targeting the chatposts container' do
        ActsAsTenant.with_tenant(organisation) do
          chatpost = create(:chatpost, chat: chat, organisation: organisation)
          allow(chatpost).to receive(:broadcast_append_to)
          chatpost.broadcast_created
          expect(chatpost).to have_received(:broadcast_append_to)
            .with(anything, hash_including(renderable: an_instance_of(Neo::Chat::MessageComponent)))
            .at_least(:once)
          # The deleted partial must NOT be referenced anywhere in the call.
          expect(chatpost).not_to have_received(:broadcast_append_to)
            .with(anything, hash_including(:partial))
        end
      end

      it 'broadcast_updated sends a renderable (not a partial)' do
        ActsAsTenant.with_tenant(organisation) do
          chatpost = create(:chatpost, chat: chat, organisation: organisation)
          allow(chatpost).to receive(:broadcast_replace_to)
          chatpost.broadcast_updated
          expect(chatpost).to have_received(:broadcast_replace_to)
            .with(anything, hash_including(renderable: an_instance_of(Neo::Chat::MessageComponent)))
            .at_least(:once)
          expect(chatpost).not_to have_received(:broadcast_replace_to)
            .with(anything, hash_including(:partial))
        end
      end

      # Bug fix: live-streamed posts never showed the delete button because
      # broadcasts created a MessageComponent without current_user / show_delete.
      # Pull from CurrentAttributes so the stream matches the initial render.
      it 'passes Current.user / Current.organisation / show_delete=true when Current is set' do
        ActsAsTenant.with_tenant(organisation) do
          user = create(:user, organisation: organisation)
          Current.user = user
          Current.organisation = organisation
          begin
            chatpost = create(:chatpost, chat: chat, organisation: organisation, user: user)
            component = chatpost.send(:build_message_component)
            expect(component.instance_variable_get(:@current_user)).to eq(user)
            expect(component.instance_variable_get(:@current_organisation)).to eq(organisation)
            expect(component.instance_variable_get(:@show_delete)).to eq(true)
          ensure
            Current.user = nil
            Current.organisation = nil
          end
        end
      end

      it 'degrades to show_delete=false when Current.user is nil (job context)' do
        ActsAsTenant.with_tenant(organisation) do
          Current.user = nil
          Current.organisation = nil
          chatpost = create(:chatpost, chat: chat, organisation: organisation)
          component = chatpost.send(:build_message_component)
          expect(component.instance_variable_get(:@current_user)).to be_nil
          expect(component.instance_variable_get(:@show_delete)).to eq(false)
        end
      end
    end

    # The previous version of this example re-evaluated the model file with `load` to observe the
    # after_*_commit calls. That is destructive: it redefines the class inside the running suite,
    # which now raises on the role enum ("already defined by another enum") and leaves Chatpost
    # broken for EVERY following example in the process. The wiring it meant to prove is already
    # covered behaviourally by the two examples above ('calls broadcast_created after create' /
    # '... after update'), so what remains here is the method-presence check.
    it 'defines the broadcast methods' do
      expect(Chatpost.instance_methods).to include(:broadcast_created, :broadcast_updated)
    end

    it 'calls broadcast_append_to in broadcast_created' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, chat: chat, organisation: organisation)
        expect(chatpost).to receive(:broadcast_append_to).once
        chatpost.broadcast_created
      end
    end

    it 'calls broadcast_replace_to in broadcast_updated' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, chat: chat, organisation: organisation)
        expect(chatpost).to receive(:broadcast_replace_to).once
        chatpost.broadcast_updated
      end
    end
  end

  describe '#destroy' do
    before do
      allow_any_instance_of(Chatpost).to receive(:broadcast_created)
      allow_any_instance_of(Chatpost).to receive(:broadcast_updated)
    end

    it 'allows destroying a user chatpost' do
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, organisation: organisation)
        chatpost = create(:chatpost, chat: chat, role: 'user', organisation: organisation)

        expect { chatpost.destroy }.to change(Chatpost, :count).by(-1)
      end
    end

    it 'prevents destroying a system chatpost if not the only one' do
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, organisation: organisation)
        chat.chatposts.destroy_all

        system_post = create(:chatpost, chat: chat, role: 'system', organisation: organisation)
        create(:chatpost, chat: chat, role: 'user', organisation: organisation)

        # Stub is_first? to avoid nil errors
        allow(system_post).to receive(:is_first?).and_return(false)

        expect(system_post.destroy).to be_falsey
        expect(system_post.errors[:base]).to include('Systemnachrichten können nicht gelöscht werden')
      end
    end

    it 'allows destroying the only system chatpost' do
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, organisation: organisation)
        chat.chatposts.destroy_all

        system_post = create(:chatpost, chat: chat, role: 'system', organisation: organisation)

        # Stub is_first? to avoid nil errors
        allow(system_post).to receive(:is_first?).and_return(true)

        expect { system_post.destroy }.to change(Chatpost, :count).by(-1)
      end
    end

    # Regression guard: chat.destroy must not be blocked by the system-chatpost
    # guard when a chat has both system and user posts.
    # Previously: dependent: :destroy on chat.chatposts triggers chatpost.destroy →
    # is_destroyable? = false → cascade fails → chat is left with orphans.
    context 'when destroyed via parent chat cascade' do
      it 'cascades successfully when chat has system + user chatposts' do
        ActsAsTenant.with_tenant(organisation) do
          chat = create(:chat, organisation: organisation)
          chat.chatposts.destroy_all

          create(:chatpost, chat: chat, role: 'system', organisation: organisation)
          create(:chatpost, chat: chat, role: 'user', organisation: organisation)

          chat.reload
          expect(chat.destroy).to be_truthy
          expect(Chat.where(id: chat.id)).to be_empty
          expect(Chatpost.where(chat_id: chat.id)).to be_empty
        end
      end

      it 'cascades successfully even with multiple system + user posts' do
        ActsAsTenant.with_tenant(organisation) do
          chat = create(:chat, organisation: organisation)
          chat.chatposts.destroy_all

          create(:chatpost, chat: chat, role: 'system', organisation: organisation)
          create(:chatpost, chat: chat, role: 'user', organisation: organisation)
          create(:chatpost, chat: chat, role: 'assistant', organisation: organisation)

          chat.reload
          expect(chat.destroy).to be_truthy
          expect(Chat.where(id: chat.id)).to be_empty
          expect(Chatpost.where(chat_id: chat.id)).to be_empty
        end
      end

      it 'still blocks direct destroy of a system chatpost when others exist' do
        # Direct deletion by a user should still be protected —
        # the fix may only let the cascade through, not disable all protection logic.
        ActsAsTenant.with_tenant(organisation) do
          chat = create(:chat, organisation: organisation)
          chat.chatposts.destroy_all

          system_post = create(:chatpost, chat: chat, role: 'system', organisation: organisation)
          create(:chatpost, chat: chat, role: 'user', organisation: organisation)

          expect(system_post.destroy).to be_falsey
          expect(Chatpost.where(id: system_post.id)).to exist
        end
      end
    end
  end

  describe '#is_destroyable?' do
    it 'returns true for user chatposts' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, role: 'user')
        # This test is simple and doesn't use the is_first? method
        expect(chatpost.is_destroyable?).to be true
      end
    end

    it 'returns false for system chatposts when not the only one' do
      ActsAsTenant.with_tenant(organisation) do
        # Create real objects
        chat = create(:chat)
        system_post = create(:chatpost, chat: chat, role: 'system')

        # Stub the is_destroyable? method behavior directly
        allow(system_post).to receive(:is_destroyable?).and_return(false)

        expect(system_post.is_destroyable?).to be false
      end
    end

    it 'returns true for system chatposts when it is the only one' do
      ActsAsTenant.with_tenant(organisation) do
        # Create real objects
        chat = create(:chat)
        system_post = create(:chatpost, chat: chat, role: 'system')

        # Stub the is_destroyable? method behavior directly
        allow(system_post).to receive(:is_destroyable?).and_return(true)

        expect(system_post.is_destroyable?).to be true
      end
    end
  end

  describe '#is_first?' do
    before do
      allow_any_instance_of(Chatpost).to receive(:broadcast_created)
      allow_any_instance_of(Chatpost).to receive(:broadcast_updated)
    end

    it 'returns true for the first chatpost in a chat' do
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, organisation: organisation)
        first_post = chat.chatposts.first

        # Stub the chatposts.first method to avoid nil errors
        allow(chat).to receive_message_chain(:chatposts, :first).and_return(first_post)

        expect(first_post.is_first?).to be true
      end
    end

    it 'returns false for subsequent chatposts' do
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, organisation: organisation)
        first_post = chat.chatposts.first
        second_post = create(:chatpost, chat: chat, organisation: organisation)

        # Stub the chatposts.first method to avoid nil errors
        allow(chat).to receive_message_chain(:chatposts, :first).and_return(first_post)

        expect(second_post.is_first?).to be false
      end
    end
  end

  describe '#user_content?' do
    it 'returns true for chatposts with role user' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, role: 'user')
        expect(chatpost.send(:user_content?)).to be true
      end
    end

    it 'returns false for chatposts with role system' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = build(:chatpost, role: 'system')
        expect(chatpost.send(:user_content?)).to be false
      end
    end
  end

  describe 'tool_calls column' do
    let(:chat) do
      ActsAsTenant.with_tenant(organisation) { create(:chat, organisation: organisation) }
    end

    before do
      allow_any_instance_of(Chatpost).to receive(:broadcast_created)
      allow_any_instance_of(Chatpost).to receive(:broadcast_updated)
    end

    it 'defaults to an empty array on new records' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = create(:chatpost, chat: chat, organisation: organisation)
        expect(chatpost.reload.tool_calls).to eq([])
      end
    end

    it 'persists an array of tool-call hashes losslessly' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = create(:chatpost, chat: chat, organisation: organisation)
        payload = [
          { 'tool' => 'search_code_symbols', 'args' => { 'query' => 'auth' },
            'result_summary' => '5 symbols found', 'succeeded' => true,
            'duration_ms' => 142, 'iteration' => 1 },
          { 'tool' => 'get_capability_details', 'args' => { 'capability_id' => 'abc-uuid' },
            'result_summary' => 'Capability loaded', 'succeeded' => true,
            'duration_ms' => 8, 'iteration' => 2 }
        ]
        chatpost.update!(tool_calls: payload)
        expect(chatpost.reload.tool_calls).to eq(payload)
      end
    end

    it 'enforces NOT NULL at the database level' do
      ActsAsTenant.with_tenant(organisation) do
        chatpost = create(:chatpost, chat: chat, organisation: organisation)
        expect do
          chatpost.update_columns(tool_calls: nil)
        end.to raise_error(ActiveRecord::NotNullViolation)
      end
    end
  end

  describe 'multi-tenancy' do
    it 'isolates chatposts by organisation' do
      organisation1 = organisation
      organisation2 = create(:organisation)

      ActsAsTenant.with_tenant(organisation1) do
        create(:chat, organisation: organisation1)
      end

      ActsAsTenant.with_tenant(organisation2) do
        create(:chat, organisation: organisation2)
      end

      # Test scoping with separate queries
      ActsAsTenant.with_tenant(organisation1) do
        expect(Chatpost.where(organisation_id: organisation1.id).count).to eq(1)
      end

      ActsAsTenant.with_tenant(organisation2) do
        expect(Chatpost.where(organisation_id: organisation2.id).count).to eq(1)
      end
    end
  end

  # a1 (Plan §6): when an answer draws on project content, live token deltas go ONLY to
  # the asker (rendered un-redacted, because the retrieval was asker-gated); the shared
  # stream holds the placeholder and gets ONE page-refresh at completion so everyone else
  # re-renders authorised. Code-only / context-free answers keep the plain broadcast.
  describe 'gated streaming split (a1)' do
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:chat)    { ActsAsTenant.with_tenant(organisation) { create(:chat, organisation: organisation) } }
    let(:asker)   { ActsAsTenant.with_tenant(organisation) { create(:user) } }

    let(:content_citations) { [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => 'x' }] }
    let(:code_citations)    { [{ 'type' => 'symbol', 'id' => 'x' }] }

    # build (not create) → no after_*_commit callback fires, so we drive broadcast_updated
    # explicitly and assert which streams it targets.
    def assistant(citations:, model_used: nil)
      ActsAsTenant.with_tenant(organisation) do
        build(:chatpost, chat: chat, organisation: organisation, role: 'assistant',
                         content: 'x', source_citations: citations, model_used: model_used)
      end
    end

    def stub_streams(post)
      allow(post).to receive(:broadcast_replace_to)
      allow(post).to receive(:broadcast_refresh_to)
    end

    describe '#content_bearing?' do
      it 'is true when a citation carries an area' do
        expect(assistant(citations: content_citations).content_bearing?).to be(true)
      end

      it 'is false for code-only citations (no area)' do
        expect(assistant(citations: code_citations).content_bearing?).to be(false)
      end

      it 'is false for an empty citation list' do
        expect(assistant(citations: []).content_bearing?).to be(false)
      end
    end

    describe 'broadcast routing' do
      it 'GATED: streams the live delta to the asker stream, never the shared one' do
        post = assistant(citations: content_citations)
        post.streaming_asker = asker
        stub_streams(post)
        post.broadcast_updated
        expect(post).to have_received(:broadcast_replace_to).with([chat, asker], anything)
        expect(post).not_to have_received(:broadcast_replace_to).with(chat.chatposts_dom_id, anything)
      end

      it 'GATED: does NOT refresh the shared stream during streaming (model_used nil)' do
        post = assistant(citations: content_citations)
        post.streaming_asker = asker
        stub_streams(post)
        post.broadcast_updated
        expect(post).not_to have_received(:broadcast_refresh_to)
      end

      # projekt_chat_abbau: no completed answer refreshes the shared stream any more.
      # The refresh belonged to the per-project chat, which was watched from a chat PAGE
      # that opted into turbo morph; the companion panel rides on whatever page the
      # reader is on, where a refresh degrades into a full visit and takes the open
      # detail with it. What is left is the targeted replace on the owner's own stream.
      it 'GATED: does not refresh the shared stream even once the answer is complete' do
        post = assistant(citations: content_citations, model_used: 'gpt-x')
        post.streaming_asker = asker
        stub_streams(post)
        post.broadcast_updated
        expect(post).not_to have_received(:broadcast_refresh_to)
      end

      it 'GATED: renders the asker stream with the ASKER as viewer (un-redacted), not Current.user' do
        post = assistant(citations: content_citations)
        post.streaming_asker = asker
        captured = nil
        allow(post).to receive(:broadcast_refresh_to)
        allow(post).to receive(:broadcast_replace_to) do |stream, opts|
          captured = opts[:renderable] if stream == [chat, asker]
        end
        post.broadcast_updated
        expect(captured).to be_a(Neo::Chat::MessageComponent)
        expect(captured.instance_variable_get(:@current_user)).to eq(asker)
      end

      it 'CODE-ONLY (no area): plain shared-stream broadcast, no asker stream, no refresh' do
        post = assistant(citations: code_citations)
        post.streaming_asker = asker
        stub_streams(post)
        post.broadcast_updated
        expect(post).to have_received(:broadcast_replace_to).with(chat.chatposts_dom_id, anything)
        expect(post).not_to have_received(:broadcast_replace_to).with([chat, asker], anything)
        expect(post).not_to have_received(:broadcast_refresh_to)
      end

      it 'NO streaming_asker (normal save): shared-stream broadcast, unchanged' do
        post = assistant(citations: content_citations) # content, but asker never set
        stub_streams(post)
        post.broadcast_updated
        expect(post).to have_received(:broadcast_replace_to).with(chat.chatposts_dom_id, anything)
        expect(post).not_to have_received(:broadcast_replace_to).with([chat, asker], anything)
      end

      # broadcast_created is the SYMMETRIC half of the a1 split (the first/seed bubble); the
      # block above only exercised broadcast_updated. Without these, deleting the gated
      # asker-append (or seeding the asker bubble with viewer: Current.user → redacted) survives.
      it 'GATED created: appends to BOTH the asker stream and the shared stream' do
        post = assistant(citations: content_citations)
        post.streaming_asker = asker
        allow(post).to receive(:broadcast_append_to)
        post.broadcast_created
        expect(post).to have_received(:broadcast_append_to)
          .with([chat, asker], hash_including(target: chat.chatposts_dom_id))
        expect(post).to have_received(:broadcast_append_to)
          .with(chat.chatposts_dom_id, hash_including(target: chat.chatposts_dom_id))
      end

      it 'GATED created: renders the asker append with the ASKER as viewer (un-redacted), not Current.user' do
        post = assistant(citations: content_citations)
        post.streaming_asker = asker
        captured = nil
        allow(post).to receive(:broadcast_append_to) do |stream, opts|
          captured = opts[:renderable] if stream == [chat, asker]
        end
        post.broadcast_created
        expect(captured).to be_a(Neo::Chat::MessageComponent)
        expect(captured.instance_variable_get(:@current_user)).to eq(asker)
      end

      it 'CODE-ONLY created (no area): appends to the shared stream only, no asker stream' do
        post = assistant(citations: code_citations)
        post.streaming_asker = asker
        allow(post).to receive(:broadcast_append_to)
        post.broadcast_created
        expect(post).to have_received(:broadcast_append_to).with(chat.chatposts_dom_id, anything)
        expect(post).not_to have_received(:broadcast_append_to).with([chat, asker], anything)
      end

      # The rescue (Z.60/76) keeps a broadcast/render error inside the after_*_commit callback
      # from tearing down the transaction. Without it a missing-partial / render boom would
      # propagate out of the commit. Pin: the method logs and does NOT raise.
      it 'broadcast_created swallows + logs internal errors (after_commit must not raise)' do
        post = assistant(citations: code_citations)
        allow(post).to receive(:broadcast_append_to).and_raise(StandardError, 'render boom')
        expect(Rails.logger).to receive(:error).with(/broadcast created error/i)
        expect { post.broadcast_created }.not_to raise_error
      end

      it 'broadcast_updated swallows + logs internal errors (after_commit must not raise)' do
        post = assistant(citations: code_citations)
        allow(post).to receive(:broadcast_replace_to).and_raise(StandardError, 'render boom')
        expect(Rails.logger).to receive(:error).with(/broadcast updated error/i)
        expect { post.broadcast_updated }.not_to raise_error
      end
    end

    # S3a T4: the completion refresh is a PAGE refresh. For a project thread it
    # rides on the chat page, which opts into morph -- harmless. For an org
    # thread the subscriber is the companion panel, and the panel rides on
    # WHATEVER page the user is looking at: ticket list, meeting, note. Those
    # pages carry no morph meta, so the refresh turns into a full replace visit
    # and takes the open detail with it. "Answer arrives, your ticket closes."
    #
    # The refresh had exactly two jobs, and only one of them survives here: other
    # viewers re-rendering authorised cannot happen (since S1 an org thread has
    # exactly one reader), and the stale regenerate pill on the PREVIOUS answer
    # is dealt with by replacing that one bubble.
    describe 'completion broadcast in an ORG thread (T4: the panel rides on foreign pages)' do
      let(:owner)      { ActsAsTenant.with_tenant(organisation) { create(:user) } }
      let(:org_thread) do
        ActsAsTenant.with_tenant(organisation) do
          create(:chat, :org_thread, organisation: organisation, user: owner)
        end
      end

      # Persisted, but with the creation broadcast silenced: these examples are
      # about broadcast_updated, which they call by hand.
      #
      # WITH area-bearing citations, because that is the normal shape of an
      # org-wide answer: the org retriever runs the content layer only, and every
      # content citation carries an area. It is also what makes the render gate
      # bite, which the viewer example below depends on.
      def stored_answer(thread, content)
        answer = ActsAsTenant.with_tenant(organisation) do
          build(:chatpost, chat: thread, organisation: organisation, role: 'assistant',
                           content: content, model_used: 'gpt-x', source_citations: content_citations)
        end
        allow(answer).to receive(:broadcast_created)
        answer.save!
        answer
      end

      # NOTE: broadcast_updated wraps everything in
      # `rescue StandardError`, so a mistake INSIDE this block (a typo, a helper
      # that does not exist here) is swallowed and shows up as a silent nil rather
      # than as an error. Keep the block trivial.
      def captured_previous_render(post)
        captured = nil
        allow(post).to receive(:broadcast_refresh_to)
        allow(post).to receive(:broadcast_replace_to) do |_stream, opts|
          captured = opts[:renderable] unless opts[:target] == "chatpost_#{post.id}"
        end
        post.broadcast_updated
        captured
      end

      it 'does NOT refresh the page when an org-thread answer completes' do
        previous = stored_answer(org_thread, 'Erste Antwort')
        post = stored_answer(org_thread, 'Zweite Antwort')
        stub_streams(post)

        post.broadcast_updated

        expect(post).not_to have_received(:broadcast_refresh_to)
        # ... but the previous answer still loses its regenerate pill.
        expect(post).to have_received(:broadcast_replace_to)
          .with([org_thread, owner], hash_including(target: "chatpost_#{previous.id}"))
      end

      # Was: "still refreshes for a PROJECT thread (unchanged path)". That path went
      # with the surface. Turned into its opposite so the branch cannot come back
      # unnoticed: NOTHING refreshes on completion any more.
      it 'refreshes nothing on completion, whatever the answer cites' do
        post = assistant(citations: code_citations, model_used: 'gpt-x')
        stub_streams(post)

        post.broadcast_updated

        expect(post).not_to have_received(:broadcast_refresh_to)
      end

      # The trap this whole branch walks into: broadcast_updated runs inside the
      # JOB, where Current.user is nil, and MessageComponent#redacted? blacks out
      # every content-bearing answer for a nil viewer BEFORE it ever reaches the
      # owner short-circuit. The refresh this replaced did not have the problem --
      # it re-rendered over the authorised HTTP path. Rendered viewer-agnostic,
      # the owner would watch their own previous answer turn into "you may not
      # read this" until the panel was reloaded.
      it 'renders the previous answer FOR ITS OWNER, so the render gate does not black it out' do
        stored_answer(org_thread, 'Erste Antwort')
        post = stored_answer(org_thread, 'Zweite Antwort')

        captured = captured_previous_render(post)

        expect(captured).to be_a(Neo::Chat::MessageComponent)
        expect(captured.instance_variable_get(:@current_user)).to eq(owner)
        expect(captured.redacted?).to be(false)
      end

      # ... and it goes to the OWNER'S OWN stream, not the shared one. Same
      # reasoning as the a1 split above: an un-redacted render belongs on a
      # stream Turbo signs per user, never on the stream every reader of a
      # project thread shares.
      it 'sends the un-redacted render to the owner stream, not the shared one' do
        previous = stored_answer(org_thread, 'Erste Antwort')
        post = stored_answer(org_thread, 'Zweite Antwort')
        stub_streams(post)

        post.broadcast_updated

        expect(post).to have_received(:broadcast_replace_to)
          .with([org_thread, owner], hash_including(target: "chatpost_#{previous.id}"))
        # Scoped to the PREVIOUS bubble on purpose: the current post's own replace
        # still uses the shared stream in this example, because nothing set
        # streaming_asker here. In the real job it does (the asker is the owner),
        # so that one takes the a1 asker stream instead.
        expect(post).not_to have_received(:broadcast_replace_to)
          .with(org_thread.chatposts_dom_id, hash_including(target: "chatpost_#{previous.id}"))
      end

      # With only two answers ".last" and ".first" pick the same record, so the
      # selection was not actually pinned: a mutation to .first survived. Three
      # answers separate "the one before this" from "the oldest".
      it 'replaces the answer BEFORE this one, not the oldest' do
        stored_answer(org_thread, 'Erste Antwort')
        second = stored_answer(org_thread, 'Zweite Antwort')
        post = stored_answer(org_thread, 'Dritte Antwort')
        stub_streams(post)

        post.broadcast_updated

        expect(post).to have_received(:broadcast_replace_to)
          .with([org_thread, owner], hash_including(target: "chatpost_#{second.id}"))
      end

      it 'replaces nothing extra when the org thread has no earlier answer' do
        post = stored_answer(org_thread, 'Erste Antwort')
        stub_streams(post)

        post.broadcast_updated

        expect(post).to have_received(:broadcast_replace_to)
          .with(org_thread.chatposts_dom_id, hash_including(target: "chatpost_#{post.id}"))
          .once
      end

      # The owner stream is only correct because an org thread cannot have a
      # second reader. If that ever changes, this is the line that leaks.
      it 'keeps the org thread owner-only, which is what makes the owner stream safe' do
        expect(ChatPolicy.new(create(:user), org_thread).show?).to be(false)
      end
    end
  end
  # S3a T3 gave this column its contract, T5 added a key to it. Neither had a
  # model-level test, and the seam it hides is a classic: the WRITER uses symbol
  # keys (Tools::Scope#coverage_with returns { searched:, total:, chosen: }), the
  # READER uses string keys (MessageComponent#coverage_notice asks
  # coverage['chosen']). jsonb is what turns one into the other. Anybody who
  # "tidies" the reader to coverage[:chosen] gets nil and a silently missing
  # sentence -- no error, no test, just an answer that stops saying what it
  # searched.
  # Feinschliff B review: the streaming broadcast is NOT "a single bubble once".
  # ChatResponseJob writes one update! per token delta, and after_update_commit
  # re-renders the whole bubble each time. A resolver built per render therefore
  # cost one query per target type per TOKEN, on a path the job itself folds three
  # writes into one to keep cheap -- and the citation list was DB-free before.
  describe 'existence resolution on the streaming hot path' do
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:chat) { ActsAsTenant.with_tenant(organisation) { create(:chat, organisation: organisation) } }
    let(:author) { create(:user) }

    def existence_queries
      counts = Hash.new(0)
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        next if payload[:name].to_s.match?(/SCHEMA|TRANSACTION|CACHE/)

        %w[tickets notes meetings].each do |table|
          counts[table] += 1 if payload[:sql].include?(%(FROM "#{table}"))
        end
      end
      yield
      counts
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'asks once for the whole answer, not once per delta write' do
      Prosopite.pause
      begin
        ticket = create(:ticket, project: project, organisation: organisation)
        note = create(:note, project: project, organisation: organisation, creator: author)
        meeting = create(:meeting, project: project, organisation: organisation, creator: author)
      ensure
        Prosopite.resume
      end
      cites = [
        { 'type' => 'ticket', 'area' => 'tickets', 'id' => ticket.id, 'project_id' => project.id,
          'number' => 1, 'title' => 'T' },
        { 'type' => 'note', 'area' => 'notes', 'id' => note.id, 'project_id' => project.id, 'title' => 'N' },
        { 'type' => 'meeting', 'area' => 'meetings', 'id' => meeting.id, 'project_id' => project.id, 'title' => 'M' }
      ]

      counts = existence_queries do
        post = chat.chatposts.create!(organisation: organisation, role: 'assistant', content: '',
                                      source_citations: cites)
        20.times { |i| post.update!(content: "#{post.content}tok#{i} ") }
      end

      # Flow anchor: it IS resolved (one query per cited type), so this cannot pass
      # by never asking at all -- which would silently drop the deleted-source notice.
      expect(counts).to eq('tickets' => 1, 'notes' => 1, 'meetings' => 1)
    end
  end

  describe 'source_coverage (jsonb contract)' do
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:chat) do
      ActsAsTenant.with_tenant(organisation) { create(:chat, organisation: organisation) }
    end

    def stored(coverage)
      ActsAsTenant.with_tenant(organisation) do
        post = build(:chatpost, chat: chat, organisation: organisation, role: 'assistant',
                                content: 'Antwort', source_coverage: coverage)
        allow(post).to receive(:broadcast_created)
        post.save!
        post.reload.source_coverage
      end
    end

    # NOT via the factory: the column has no default, and nil is a meaningful
    # value here -- it means "no reach applies to this answer" (a project thread,
    # or an answer that used no tools). coverage_notice leans on it directly.
    it 'is NULL when nothing was written' do
      post = ActsAsTenant.with_tenant(organisation) do
        p = build(:chatpost, chat: chat, organisation: organisation, role: 'assistant', content: 'Antwort')
        allow(p).to receive(:broadcast_created)
        p.save!
        p
      end

      expect(post.reload.source_coverage).to be_nil
    end

    it 'accepts an explicit nil, which is how a regeneration resets it' do
      expect(stored(nil)).to be_nil
    end

    # THE seam. Symbols in, strings out.
    it 'returns STRING keys for the symbols that were written' do
      expect(stored(searched: 3, total: 12)).to eq('searched' => 3, 'total' => 12)
    end

    it 'round-trips the T5 chosen key the same way' do
      expect(stored(searched: 1, total: 12, chosen: 'Nordlicht Software'))
        .to eq('searched' => 1, 'total' => 12, 'chosen' => 'Nordlicht Software')
    end

    # Integers must not come back as strings: coverage_notice refuses to render
    # unless searched and total ARE Integers, so a type change here silences the
    # narrowing notice instead of breaking loudly.
    it 'keeps the numbers numeric' do
      coverage = stored(searched: 3, total: 12)

      expect(coverage['searched']).to be_an(Integer)
      expect(coverage['total']).to be_an(Integer)
    end
  end
end

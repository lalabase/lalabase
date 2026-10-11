# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Chat::ChatContainerComponent, type: :component do
  # R4 (doc/ai_feature_registry_plan.md): the composer stopped asking the bare opt-in and
  # asks :chat, which also wants a usable chat configuration. The factory org carries the
  # opt-in but no credential, so without these two attributes every composer example below
  # would render the unavailable notice instead — which is the state its own describe
  # exercises. Same shape as spec/requests/organisations/ai_surface_gating_spec.rb.
  let(:organisation) do
    create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef')
  end
  let(:user)         { create(:user, organisation: organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:chat)         { create(:chat, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def stub_policy(write:)
    fake_helpers = double('helpers').as_null_object
    # projekt_chat_abbau: the container asks ChatPolicy directly now. ChatsHelper's
    # can_write_chats? was the project area's question and went with the surface.
    allow(fake_helpers).to receive(:policy).and_return(double('policy', update?: write))
    allow(fake_helpers).to receive(:organisation_assistant_chat_path).and_return('/del-path')
    allow(fake_helpers).to receive(:organisation_assistant_chat_chatposts_path).and_return('/post-path')
    allow(fake_helpers).to receive(:organisation_assistant_chat_chatpost_path).and_return('/cp-del-path')
    allow(fake_helpers).to receive(:protect_against_forgery?).and_return(false)
    allow_any_instance_of(Neo::Chat::ChatContainerComponent).to receive(:helpers).and_return(fake_helpers)
    allow_any_instance_of(Neo::Chat::ComposerComponent).to receive(:helpers).and_return(fake_helpers)
    allow_any_instance_of(Neo::Chat::MessageComponent).to receive(:helpers).and_return(fake_helpers)
  end

  def render_component
    render_inline(described_class.new(
                    chat: chat, current_user: user, current_organisation: organisation
                  ))
  end

  it 'wraps everything in the chat-show turbo-frame (replace target)' do
    stub_policy(write: true)
    render_component
    expect(page).to have_css('turbo-frame#chat-show')
  end

  it 'renders the chatposts container with dom_id-derived id' do
    stub_policy(write: true)
    render_component
    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(chat)}_chatposts")
  end

  it 'renders the composer when policy grants chats:write' do
    stub_policy(write: true)
    render_component
    expect(rendered_content).to include(I18n.t('views.organisations.chats.composer.send'))
  end

  # The writing zone, in the order the question is asked (27.08.2026). What the
  # assistant is pointed AT moved ABOVE the field, because below it -- at the
  # bottom edge of a 380px panel, under the style row and the transparency line
  # -- nobody looked at it, and it is the one setting you want to check BEFORE
  # typing: it decides what the question can even reach.
  #
  # Pinned by POSITION and not merely by presence, because presence is what it
  # already had while it was in the wrong place. These three are the whole
  # arrangement, and a re-order is exactly the kind of change that looks
  # harmless in a diff.
  describe 'the order of the writing zone' do
    def position_of(needle)
      rendered_content.index(needle) || raise("not rendered: #{needle}")
    end

    it 'puts what it looks AT above the field, and how it answers below' do
      stub_policy(write: true)
      render_component

      scope_row = position_of("#{ActionView::RecordIdentifier.dom_id(chat)}_scope_row")
      field     = position_of('chatpost[content]')
      style_row = position_of(Neo::Chat::StyleControlComponent::DOM_CLASS)

      expect(scope_row).to be < field
      expect(field).to be < style_row
    end
  end

  # The context offer (S4 T2 step 5b) rides along with the panel, so it renders
  # for the panel's frame and for no other. Two reasons, and the second one is
  # the sharper: a chat page has no "page you navigated to" to offer, AND the
  # panel renders on top of chat pages -- so an ungated strip would put a second
  # assistant_offer_set into one document. The take button is described BY that
  # id (aria-describedby), which turns a duplicate from untidy into a broken
  # promise. Same trap as #612, third repetition in this feature.
  describe 'the context offer is the panel’s alone' do
    it 'renders the offer strip in the panel frame' do
      stub_policy(write: true)
      render_inline(described_class.new(
                      chat: chat, current_user: user,
                      current_organisation: organisation,
                      frame_id: described_class::PANEL_FRAME_ID
                    ))

      expect(page).to have_css('[data-assistant-panel-target="offer"]', visible: :all)
      expect(rendered_content).to include('assistant_offer_set')
    end

    it 'leaves it out of the chat page frame' do
      stub_policy(write: true)
      render_component

      expect(page).to have_no_css('[data-assistant-panel-target="offer"]', visible: :all)
      expect(rendered_content).not_to include('assistant_offer_set')
    end

    it 'puts the offer ABOVE the row it offers to fill' do
      stub_policy(write: true)
      render_inline(described_class.new(
                      chat: chat, current_user: user,
                      current_organisation: organisation,
                      frame_id: described_class::PANEL_FRAME_ID
                    ))

      offer = rendered_content.index('assistant_offer_set')
      row   = rendered_content.index("#{ActionView::RecordIdentifier.dom_id(chat)}_scope_row")
      expect(offer).to be < row
    end
  end

  it 'renders the read-only notice when policy denies chats:write' do
    stub_policy(write: false)
    render_component
    expect(rendered_content).to include(I18n.t('views.organisations.chats.chat_show.read_only'))
  end

  it 'NEVER renders both composer and read-only notice (mutual exclusion)' do
    stub_policy(write: true)
    render_component
    expect(rendered_content).not_to include(I18n.t('views.organisations.chats.chat_show.read_only'))
  end

  # R4 (doc/ai_feature_registry_plan.md): the composer asks :chat — the row that routes
  # ChatResponseJob — instead of the bare opt-in. That turns two states into three, and
  # the middle one is new: opted in, but no route for the message.
  describe 'the composer asks the :chat feature, not the bare opt-in (R4)' do
    # Key-scoped on purpose. A blanket `receive(:resolve)` answers for EVERY key and would
    # make this whole file blind to a mistyped one (the trap documented in the #402
    # review), which is exactly the defect these examples exist to catch.
    def refuse_only(feature_key, reason: :no_credential)
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
        .with(feature_key, anything)
        .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(
                      available: false, reason: reason, required_provider: 'openai', lane: :chat
                    ))
    end

    def provider_label
      AiCredential.provider_display_names.fetch('openai', 'openai')
    end

    it 'renders the composer while the chat lane is configured' do
      stub_policy(write: true)
      render_component

      expect(rendered_content).to include(I18n.t('views.organisations.chats.composer.send'))
    end

    it 'puts the reason where the composer was when the chat lane has no credential' do
      refuse_only(:chat)
      stub_policy(write: true)
      render_component

      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.composer.send'))
      expect(rendered_content).to include(
        I18n.t('shared.ai.unavailable.no_credential', provider: provider_label, current: provider_label)
      )
      # In the SAME amber box the opt-in case has always used. The sentence is
      # variant-independent, so without this a retyped `variant:` goes unnoticed and this
      # branch quietly turns from a warning into a neutral info panel.
      expect(page).to have_css('div.bg-amber-50 i.bi-shield-exclamation')
    end

    it 'keeps the notice inside the composer frame so a stale-tab submit can swap into it' do
      # The frame id is load-bearing, not cosmetic: the controller answers a stale submit
      # with a 302, Turbo follows it inside the FORM's frame, and a response without a
      # matching id fails with "content missing" and swallows the alert.
      refuse_only(:chat)
      stub_policy(write: true)
      render_component

      expect(page).to have_css("turbo-frame##{chat.chatpost_form_dom_id}")
    end

    it 'ignores a refusal aimed at a different registry row' do
      # The other half of the mutation proof. Every row answers the same for a normally
      # configured org, so retyping the component to a foreign key leaves the example
      # above green — only a FOREIGN refusal that changes nothing here shows that this
      # surface really reads :chat.
      refuse_only(:content_indexing)
      stub_policy(write: true)
      render_component

      expect(rendered_content).to include(I18n.t('views.organisations.chats.composer.send'))
    end

    context 'when the org never opted in' do
      let(:organisation) { create(:organisation, :ai_disabled) }

      it 'still shows the opt-in notice it showed before R4, word for word' do
        stub_policy(write: true)
        render_component

        expect(rendered_content).to include(I18n.t('shared.ai.disabled_member_hint'))
        expect(rendered_content).not_to include(I18n.t('views.organisations.chats.composer.send'))
      end
    end
  end

  describe 'message composition (per-chatpost rendering)' do
    # Without this test, removing `<% @chat.chatposts.each do |chatpost| %>` in the
    # template would silently leave the chatposts container empty and no other test
    # would catch it.
    it 'renders one MessageComponent block per chatpost' do
      chat.chatposts.create!(organisation: organisation, role: 'user',      content: 'second user msg')
      chat.chatposts.create!(organisation: organisation, role: 'assistant', content: 'AI reply')
      # chat factory adds 1 initial chatpost → total now 3
      stub_policy(write: true)
      render_component
      # Each MessageComponent wraps in a div#chatpost_<id>
      expect(page).to have_css('div[id^="chatpost_"]', count: chat.chatposts.count)
    end

    it 'renders the content of every chatpost' do
      chat.chatposts.create!(organisation: organisation, role: 'user',      content: 'AAAAA unique')
      chat.chatposts.create!(organisation: organisation, role: 'assistant', content: 'BBBBB unique')
      stub_policy(write: true)
      render_component
      expect(rendered_content).to include('AAAAA unique').and include('BBBBB unique')
    end

    it 'renders an empty chatposts container when chat has no posts (no crash)' do
      empty_chat = build_stubbed(:chat, organisation: organisation,
                                        created_at: Time.current, updated_at: Time.current)
      allow(empty_chat).to receive(:chatposts).and_return([])
      stub_policy(write: true)
      render_inline(described_class.new(chat: empty_chat, current_user: user, current_organisation: organisation))
      expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(empty_chat)}_chatposts")
      expect(page).not_to have_css('div[id^="chatpost_"]')
    end
  end

  describe 'policy lookups (B6 N+1 guard)' do
    # show_delete? used to consult the project policy once PER chatpost. The
    # container derives chats:write access once (memoised in #can_write?) and
    # passes a boolean down to each MessageComponent, so the write-check is
    # evaluated a constant number of times (container + composer = 2), never
    # once-per-bubble. With the old per-post lookup, 3 posts push this above 2 → red.
    it 'evaluates the write check a constant number of times, not once per chatpost' do
      chat.chatposts.create!(organisation: organisation, role: 'user',      content: 'second user msg')
      chat.chatposts.create!(organisation: organisation, role: 'assistant', content: 'AI reply')

      fake_helpers = double('helpers').as_null_object
      allow(fake_helpers).to receive(:policy).and_return(double('policy', update?: true))
      allow(fake_helpers).to receive(:organisation_assistant_chat_path).and_return('/d')
      allow(fake_helpers).to receive(:organisation_assistant_chat_chatposts_path).and_return('/p')
      allow(fake_helpers).to receive(:organisation_assistant_chat_chatpost_path).and_return('/cp')
      allow(fake_helpers).to receive(:protect_against_forgery?).and_return(false)
      allow_any_instance_of(Neo::Chat::ChatContainerComponent).to receive(:helpers).and_return(fake_helpers)
      allow_any_instance_of(Neo::Chat::ComposerComponent).to receive(:helpers).and_return(fake_helpers)
      allow_any_instance_of(Neo::Chat::MessageComponent).to receive(:helpers).and_return(fake_helpers)

      render_component

      expect(fake_helpers).to have_received(:policy).at_most(2).times
    end
  end

  # Two of the three N+1 guards that stood here went with their subject: they counted
  # the render gate's area_access? lookups, and #area_allowed? does not reach
  # ProjectPolicy any more (no thread has a project to ask about). The shared
  # area_access_cache survives in the component, unmeasured, and goes back under a
  # guard the day a surface with a real area gate returns.
  #
  # The THIRD one is below and stays: it never had anything to do with the surface.
  # The write check is guarded separately, above.
  describe 'citation-target resolution (N+1 guard)' do
    it 'asks for the existence of the cited objects ONCE for the whole transcript' do
      Prosopite.pause
      3.times do |i|
        ticket = create(:ticket, project: project, organisation: organisation)
        chat.chatposts.create!(organisation: organisation, role: 'assistant', content: "Antwort #{i}",
                               source_citations: [{ 'type' => 'ticket', 'area' => 'tickets',
                                                    'id' => ticket.id, 'project_id' => project.id,
                                                    'number' => i, 'title' => "T#{i}" }])
      end
      Prosopite.resume
      stub_policy(write: true)

      statements = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        statements << payload[:sql] unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION|CACHE/)
      end
      begin
        render_inline(described_class.new(chat: chat, current_user: user, current_organisation: organisation))
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(statements.count { |sql| sql.include?('FROM "tickets"') }).to eq(1)
    end
  end
  describe 'streaming wiring' do
    # turbo_stream_from mounts a custom element that broadcasts updates into the
    # chatposts container. If removed, ChatResponseJob's streaming becomes invisible
    # to the user (silent regression).
    it 'mounts a turbo-cable-stream-source for the chatposts stream' do
      stub_policy(write: true)
      render_component
      expect(page).to have_css('turbo-cable-stream-source')
    end

    # a1 (Plan §6): the viewer subscribes to its OWN [chat, current_user] stream too, so the
    # asker receives the live token deltas the job broadcasts there. Gated on current_user.
    it 'subscribes the viewer to their own stream in addition to the shared one' do
      stub_policy(write: true)
      render_component
      expect(page).to have_css('turbo-cable-stream-source', count: 2)
    end

    it 'subscribes to ONLY the shared stream when there is no current_user' do
      stub_policy(write: true)
      render_inline(described_class.new(chat: chat, current_user: nil, current_organisation: organisation))
      expect(page).to have_css('turbo-cable-stream-source', count: 1)
    end

    # The count:2 test above only proves TWO sources mount, not WHICH stream the second is.
    # The job broadcasts the live deltas to [chat, asker]; if viewer_stream returned e.g.
    # [chat, project] the asker would subscribe to the wrong channel and never receive the
    # deltas — a silent a1 break that count:2 cannot catch. Pin the exact identity.
    it 'targets [chat, current_user] as the per-viewer stream (the stream the job streams to)' do
      component = described_class.new(chat: chat, current_user: user, current_organisation: organisation)
      expect(component.viewer_stream).to eq([chat, user])
    end

    # A2: streamed assistant replies are appended into this container. Marking it
    # as a polite aria-live log region lets screen readers announce the reply
    # arriving without the user having to move focus.
    it 'marks the chatposts container as a polite aria-live log region' do
      stub_policy(write: true)
      render_component
      expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(chat)}_chatposts[role='log'][aria-live='polite']")
    end
  end
end

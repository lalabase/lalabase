# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Chat::ComposerComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user)         { create(:user, organisation: organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:chat)         { create(:chat, organisation: organisation) }
  let(:chatpost)     { Chatpost.new }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def stub_policy(write:)
    fake_helpers = double('helpers').as_null_object
    allow(fake_helpers).to receive(:can_write_chats?).and_return(write)
    allow(fake_helpers).to receive(:organisation_assistant_chat_path).and_return('/del-path')
    allow(fake_helpers).to receive(:organisation_assistant_chat_chatposts_path).and_return('/post-path')
    allow(fake_helpers).to receive(:protect_against_forgery?).and_return(false)
    allow_any_instance_of(described_class).to receive(:helpers).and_return(fake_helpers)
  end

  def render_component
    render_inline(described_class.new(chat: chat, chatpost: chatpost,
                                      current_organisation: organisation))
  end

  describe 'send button' do
    before { stub_policy(write: true) }

    it 'renders with the send label' do
      render_component
      expect(rendered_content).to include(I18n.t('views.organisations.chats.composer.send'))
    end

    it 'renders the textarea placeholder from i18n' do
      render_component
      expect(page).to have_css("textarea[placeholder='#{I18n.t('views.organisations.chats.composer.placeholder')}']")
    end

    # A2: the textarea has no visible <label>, so it needs an accessible name
    # for screen readers (placeholder alone is not a reliable label).
    it 'gives the textarea an accessible aria-label' do
      render_component
      expect(page).to have_css("textarea[aria-label='#{I18n.t('views.organisations.chats.composer.message_label')}']")
    end
  end

  describe 'delete button' do
    # Whole-chat delete moved to the session list (per-row hover icon,
    # 2026-07-18 feedback) — the composer must not render it anymore,
    # regardless of the write verdict.
    it 'is not rendered even when policy grants chats:write' do
      stub_policy(write: true)
      render_component
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.composer.delete_chat'))
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end
  end

  describe 'frame id' do
    it 'is derived from the chat dom id' do
      stub_policy(write: true)
      expect(described_class.new(chat: chat, chatpost: chatpost,
                                 current_organisation: organisation).frame_id)
        .to eq("#{ActionView::RecordIdentifier.dom_id(chat)}_chatpost_form")
    end

    it 'wraps the form in a turbo-frame with the matching id (so create.turbo_stream targets it)' do
      stub_policy(write: true)
      render_component
      expect(page).to have_css("turbo-frame##{ActionView::RecordIdentifier.dom_id(chat)}_chatpost_form")
    end
  end

  describe 'form contract' do
    before { stub_policy(write: true) }

    it 'submits via POST to the chatposts collection path' do
      render_component
      form = page.find('form')
      expect(form[:method].to_s.downcase).to eq('post')
      expect(form[:action]).to eq('/post-path')
    end

    it 'uses chatpost[content] as the textarea name (controller param contract)' do
      render_component
      expect(page).to have_css('textarea[name="chatpost[content]"]')
    end

    it 'localises the placeholder to the literal German string (catches key drift)' do
      # i18n key + de.yml value must both change in lockstep — this catches the case
      # where someone renames the key in the template and not in the locale (or vice versa).
      I18n.with_locale(:de) do
        render_component
        expect(page).to have_css('textarea[placeholder="Nachricht eingeben..."]')
      end
    end

    # Enter-to-send is JS, but the SERVER-side wiring (the data attributes the
    # Stimulus controller binds to) is pinnable here. A mutation removing them
    # silently kills the feature — and the JS unit test can't run (no jest runner).
    it 'wires the Enter-to-send Stimulus controller via data attributes' do
      render_component
      expect(page).to have_css('form[data-controller~="neo-chat-composer"]')
      expect(page).to have_css('textarea[data-action~="keydown->neo-chat-composer#submitOnEnter"]')
    end
  end

  # assistant_panel#guardPendingMeetingIntentSubmit refuses this form while a
  # meeting reference is still being added, and explains it here. An open thread
  # is where that happens -- and DraftReferencesComponent, which carried the only
  # status before, renders for a new chat only, so the block was silent there.
  describe 'pending meeting reference status' do
    let(:status_selector) { 'form p[data-composer-status][role="alert"][hidden]' }

    it 'renders hidden and empty in a reply form, carrying the pending_reference label' do
      stub_policy(write: true)
      render_component
      status = page.find(status_selector, visible: :all)
      expect(status['data-pending-reference-label']).to eq(I18n.t('assistant_suggestions.pending_reference'))
      expect(status.text(:all)).to be_empty
    end
  end

  # The template library's manage button is a switch; the controller keeps
  # aria-pressed in step with its mode, the markup provides the starting state.
  describe 'analysis template management' do
    before { stub_policy(write: true) }

    it 'renders the manage toggle as an unpressed switch' do
      render_component
      expect(page).to have_css('button[data-meeting-analysis-composer-target="manage"][aria-pressed="false"]', visible: :all)
    end

    it 'ends management mode when the tools fold shut' do
      render_component
      expect(page).to have_css('details[data-meeting-analysis-composer-target="tools"]' \
                               '[data-action~="toggle->meeting-analysis-composer#toolsToggled"]', visible: :all)
    end
  end

  # mode: :new_chat renders the FIRST message of a chat that does not exist yet.
  # It used to be a hand-maintained copy in new.html.erb + _new_form.html.erb and
  # silently missed every composer restyle. These specs pin the two things that
  # must stay identical to the reply composer (field styling + Stimulus wiring)
  # and the three that must differ (POST target, param nesting, no turbo frame).
  describe 'mode: :new_chat' do
    let(:chat) { Chat.new(organisation: organisation) }
    let(:persona) { create(:prompt_persona, organisation: organisation) }

    before do
      fake_helpers = double('helpers').as_null_object
      # Distinct stubs so an assertion proves the branch, not just "some path".
      allow(fake_helpers).to receive(:organisation_assistant_chats_path).and_return('/new-chat-path')
      allow(fake_helpers).to receive(:organisation_assistant_chat_chatposts_path).and_return('/reply-path')
      allow(fake_helpers).to receive(:protect_against_forgery?).and_return(false)
      allow_any_instance_of(described_class).to receive(:helpers).and_return(fake_helpers)
    end

    def render_new_chat
      render_inline(described_class.new(chat: chat, chatpost: Chatpost.new,
                                        current_organisation: organisation, mode: :new_chat,
                                        current_user: user))
    end

    it 'posts to the assistant_chats collection, not to a chatposts endpoint' do
      render_new_chat
      expect(page).to have_css("form[action='/new-chat-path']")
      expect(page).to have_no_css("form[action='/reply-path']")
    end

    it 'nests the message as a chatpost attribute (assistant_chats#create param contract)' do
      render_new_chat
      expect(page).to have_css('textarea[name="chat[chatposts_attributes][0][content]"]')
      expect(page).to have_css('input[type="hidden"][name="chat[chatposts_attributes][0][user_id]"]', visible: :all)
    end

    # THE regression this mode exists for: the first-message field must carry the
    # same look and Stimulus wiring as the reply composer. If someone restyles
    # one of them only, this breaks.
    it 'renders the field with the SAME classes and wiring as the reply composer' do
      render_new_chat
      field = page.find('textarea')
      expect(field[:class]).to eq(described_class::MESSAGE_FIELD_CLASSES)
      expect(field[:rows].to_s).to eq('1')
      expect(field['data-action']).to include('keydown->neo-chat-composer#submitOnEnter')
      expect(field['data-action']).to include('input->neo-chat-composer#autogrow')
      expect(field['data-neo-chat-composer-target']).to eq('field')
      expect(page).to have_css('form[data-controller~="neo-chat-composer"]')
    end

    it 'renders the same inline send button as the reply composer' do
      render_new_chat
      expect(page).to have_css('button[type="submit"][data-neo-chat-composer-target="send"]')
    end

    it 'renders the same pending meeting reference status as the reply composer' do
      render_new_chat
      status = page.find('form p[data-composer-status][role="alert"][hidden]', visible: :all)
      expect(status['data-pending-reference-label']).to eq(I18n.t('assistant_suggestions.pending_reference'))
    end

    # A turbo frame here would capture assistant_chats#create's answer instead of
    # letting it update the panel — the exact bug this mode replaced.
    it 'renders NO turbo frame around the form' do
      render_new_chat
      expect(page).to have_no_css('turbo-frame')
    end

    # projekt_chat_abbau took the per-conversation persona picker with the surface
    # that had it: the assistant carries ONE standing persona per person
    # (Neo::Chat::PersonaControlComponent, in the settings menu). Asserted as an
    # ABSENCE rather than deleted, because chats.prompt_persona_id and
    # Chat#resolved_persona are untouched -- bringing the per-conversation choice back
    # is a UI slice, and this is the line that has to change when somebody does.
    it 'renders no persona picker: the choice is standing, not per conversation' do
      render_new_chat
      expect(page).to have_no_css('select[name="chat[prompt_persona_id]"]')
    end
  end

  describe 'mode validation' do
    it 'rejects an unknown mode instead of silently rendering the reply form' do
      expect do
        described_class.new(chat: chat, chatpost: chatpost,
                            current_organisation: organisation, mode: :bogus)
      end.to raise_error(ArgumentError, /unknown composer mode/)
    end
  end
end

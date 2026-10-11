# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meeting context before the first message', type: :request do
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: user) }
  let(:key) { Assistant::ReferenceRegistry.key_of(meeting) }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def submit(keys, content: 'Bitte fasse den Bezug zusammen.')
    post organisation_assistant_chats_path(organisation),
         params: { chat: { reference_keys: keys, chatposts_attributes: [{ content: content }] } },
         as: :turbo_stream
  end

  it 'renders an offer and draft references without creating a conversation' do
    expect do
      get organisation_assistant_panel_path(organisation, new: '1')
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { Chat.count } })
    html = Nokogiri::HTML.fragment(response.body)
    expect(html.at_css('[data-assistant-panel-target="offer"]')).to be_present
    expect(html.at_css('form [data-assistant-panel-target="draftReferences"]')).to be_present
  end

  it 'stores the selected reference before enqueueing the very first answer' do
    expected = [{ 'type' => 'Meeting', 'id' => meeting.id }]
    expect(ChatResponseJob).to receive(:perform_later) do |chat|
      expect(Chat.find(chat.id).scope_references).to eq(expected)
    end
    submit([key, key])
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-reference-keys', key)
  end

  # Mixed references travel through the same draft save and are available to the first answer.
  it 'stores a note and a document selected before the very first answer' do
    note = create(:note, project: project, organisation: organisation, creator: user)
    document = create(:document, project: project, organisation: organisation, creator: user)
    expected = [{ 'type' => 'Meeting', 'id' => meeting.id }, { 'type' => 'Note', 'id' => note.id },
                { 'type' => 'Document', 'id' => document.id }]
    expect(ChatResponseJob).to receive(:perform_later) do |chat|
      expect(Chat.find(chat.id).scope_references).to eq(expected)
    end
    submit([key, Assistant::ReferenceRegistry.key_of(note), Assistant::ReferenceRegistry.key_of(document)])
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(Assistant::ReferenceRegistry.key_of(note))
  end

  it 'preserves the message and valid reference after a failed submission' do
    submit([key], content: '')
    expect(response).to have_http_status(:unprocessable_content)
    html = Nokogiri::HTML.fragment(response.body)
    expect(html.at_css(%(input[name="chat[reference_keys][]"][value="#{key}"]))['value']).to eq(key)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'refuses an inaccessible reference without saving a chat or starting an answer' do
    foreign = ActsAsTenant.without_tenant { create(:meeting, title: 'SECRET OTHER TENANT') }
    expect do
      submit([Assistant::ReferenceRegistry.key_of(foreign)])
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { [Chat.count, Chatpost.count] } })
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('flash.assistant_chats.reference_error'))
    expect(response.body).not_to include('SECRET OTHER TENANT', foreign.id)
    expect(response.body).to include('Bitte fasse den Bezug zusammen.')
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'keeps only readable references and the message when a mixed selection is refused' do
    selected = key
    foreign = ActsAsTenant.without_tenant { create(:meeting, title: 'SECRET OTHER TENANT') }
    expect do
      submit([selected, Assistant::ReferenceRegistry.key_of(foreign)])
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { [Chat.count, Chatpost.count] } })
    expect(response).to have_http_status(:unprocessable_content)
    html = Nokogiri::HTML.fragment(response.body)
    expect(html.at_css(%(input[name="chat[reference_keys][]"][value="#{selected}"]))).to be_present
    expect(response.body).to include('Bitte fasse den Bezug zusammen.')
    expect(response.body).not_to include('SECRET OTHER TENANT', foreign.id)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'refuses a reference after read access within the same organisation is removed' do
    selected = key
    Membership.find_by!(user: user).update!(role: create(:role, organisation: organisation, title: 'Assistant only'))
    role = Membership.find_by!(user: user).role
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    submit([selected])
    expect(response).to have_http_status(:unprocessable_content)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'refuses a reference whose project was archived before sending' do
    selected = key
    project.update!(archived_at: Time.current)
    submit([selected])
    expect(response).to have_http_status(:unprocessable_content)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'rejects malformed keys instead of silently answering without the requested context' do
    submit(['User:invalid'])
    expect(response).to have_http_status(:unprocessable_content)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'refuses more than the reference limit' do
    keys = Array.new(Assistant::ReferenceRegistry::MAX_REFERENCES + 1) { "Meeting:#{SecureRandom.uuid}" }
    submit(keys)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('flash.assistant_chats.reference_limit', count: 10))
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end
end

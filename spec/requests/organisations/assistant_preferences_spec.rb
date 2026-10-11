# frozen_string_literal: true

require 'rails_helper'

# The assistant's settings: the gear in the panel header opens a third STATE of
# the panel frame, and the persona picked there is the person's standing choice
# (doc/assistent_persona_einstellungen_plan.md).
#
# Request level, because all three things that can go wrong here are:
#
#   1. the settings render for somebody whose assistant gate is CLOSED,
#   2. the write accepts a persona the picker never offered (a foreign org's row,
#      whose prompt fragment would then reach the system prompt),
#   3. the way back out of the settings loses the thread it was opened from.
RSpec.describe 'Assistant settings and the persona choice', type: :request do
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:assistant_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: "Assistant #{SecureRandom.hex(3)}")
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      role
    end
  end

  def member_with_assistant_access
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: assistant_role, active: true)
    end
    user
  end

  def member_without_assistant_access
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: "Plain #{SecureRandom.hex(3)}", is_default: true)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let(:owner) { member_with_assistant_access }
  let!(:persona) { create(:prompt_persona, key: 'deep_dive') }

  # The request cycle sets the tenant and clears it again, so a read AFTER the
  # request has to put it back. Through one helper rather than a with_tenant block
  # per example: the point of each example is the stored value, not the plumbing.
  def stored_persona_id
    ActsAsTenant.with_tenant(organisation) do
      ChatStylePreference.find_by(user: owner, organisation: organisation)&.prompt_persona_id
    end
  end

  def own_thread
    ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, organisation: organisation, user: owner) }
  end

  # ---------------------------------------------------------------------------
  # 1. The settings state of the panel frame
  # ---------------------------------------------------------------------------
  describe 'GET the panel with settings=1' do
    it 'serves the settings into the panel frame, with the picker' do
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, settings: '1')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-assistant-settings')
      expect(response.body).to include(Neo::Chat::PersonaControlComponent::DOM_CLASS)
      # The factory's DE label, which is what the picker prints under the
      # default locale.
      expect(response.body).to include('Test-Persona')
    end

    # The transcript must NOT come along. Two chatposts containers in one panel
    # and a streaming broadcast lands in whichever Turbo finds first -- the same
    # reason the history list replaces rather than joins.
    it 'replaces the transcript instead of rendering it too' do
      chat = own_thread
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, settings: '1', current: chat.id)

      expect(response.body).not_to include(chat.chatposts_dom_id)
    end

    # The way back is what the ?current= is FOR. Without it the back link points at
    # the panel default, i.e. the newest thread, which switches the conversation
    # under somebody who pressed a button twice.
    it 'carries the way back to the thread it was opened from' do
      chat = own_thread
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, settings: '1', current: chat.id)

      expect(response.body).to include("chat_id=#{chat.id}")
    end

    # `current` is client-settable and ends up in a rendered link. A foreign id
    # must not name a thread this person cannot see.
    it 'ignores a thread that is not the requesting person\'s own' do
      foreign = ActsAsTenant.with_tenant(organisation) do
        create(:chat, :org_thread, organisation: organisation, user: member_with_assistant_access)
      end
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, settings: '1', current: foreign.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("chat_id=#{foreign.id}")
    end

    it 'refuses somebody whose assistant gate is closed' do
      sign_in member_without_assistant_access

      get organisation_assistant_panel_path(organisation_id: organisation.id, settings: '1')

      expect(response).not_to have_http_status(:ok)
    end

    # An unseeded pool is a real state on production today, and a select with
    # nothing in it would be worse than a sentence saying so.
    it 'explains itself instead of showing an empty picker when no persona exists' do
      PromptPersona.delete_all
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, settings: '1')

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(Neo::Chat::PersonaControlComponent::DOM_CLASS)
      expect(response.body).to include(I18n.t('views.organisations.assistant_panels.settings.no_personas'))
    end
  end

  # ---------------------------------------------------------------------------
  # 2. The write
  # ---------------------------------------------------------------------------
  describe 'PATCH the assistant preference' do
    it 'stores the chosen persona for this person in this organisation' do
      sign_in owner

      patch organisation_assistant_preference_path(organisation_id: organisation.id),
            params: { chat_style_preference: { prompt_persona_id: persona.id } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(stored_persona_id).to eq(persona.id)
    end

    # The blank option is a real choice, not padding: it is how somebody who
    # picked one gets back out to the organisation's default.
    it 'clears the choice when the blank option is submitted' do
      ChatStylePreference.set_persona!(user: owner, organisation: organisation, prompt_persona_id: persona.id)
      sign_in owner

      patch organisation_assistant_preference_path(organisation_id: organisation.id),
            params: { chat_style_preference: { prompt_persona_id: '' } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(stored_persona_id).to be_nil
    end

    # The one that matters: a persona belonging to ANOTHER organisation carries a
    # prompt fragment that would reach this org's system prompt.
    it 'refuses a persona from another organisation and stores nothing' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) { create(:prompt_persona, organisation: other_org, key: 'theirs') }
      sign_in owner

      patch organisation_assistant_preference_path(organisation_id: organisation.id),
            params: { chat_style_preference: { prompt_persona_id: foreign.id } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(stored_persona_id).to be_nil
      # The status ALONE proves nothing here: Rails maps RecordInvalid to 422 in
      # its exception middleware, so a controller that dropped this check and let
      # the model validation raise would answer 422 too. Measured -- with the
      # check removed both this example and the deactivated one below stayed green
      # on the status. The re-rendered control is what only the deliberate refusal
      # produces.
      expect(response.body).to include(Neo::Chat::PersonaControlComponent::DOM_CLASS)
    end

    # Reachable without crafting anything: a persona deactivated between the
    # render and the change event lands here.
    it 'refuses a persona that has been deactivated' do
      persona.update!(active: false)
      sign_in owner

      patch organisation_assistant_preference_path(organisation_id: organisation.id),
            params: { chat_style_preference: { prompt_persona_id: persona.id } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(stored_persona_id).to be_nil
      # Same reason as above: the refusal has to be OURS, not a mapped exception.
      expect(response.body).to include(Neo::Chat::PersonaControlComponent::DOM_CLASS)
    end

    it 'refuses somebody whose assistant gate is closed' do
      sign_in member_without_assistant_access

      patch organisation_assistant_preference_path(organisation_id: organisation.id),
            params: { chat_style_preference: { prompt_persona_id: persona.id } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).not_to have_http_status(:ok)
      expect(ActsAsTenant.with_tenant(organisation) { ChatStylePreference.count }).to eq(0)
    end

    # The refused path re-renders the control rather than answering with an empty
    # body: otherwise the select keeps showing the value that was just refused
    # with nothing to say it did not take.
    it 'snaps the control back to what is actually stored when it refuses' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) { create(:prompt_persona, organisation: other_org, key: 'theirs') }
      sign_in owner

      patch organisation_assistant_preference_path(organisation_id: organisation.id),
            params: { chat_style_preference: { prompt_persona_id: foreign.id } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response.body).to include(Neo::Chat::PersonaControlComponent::DOM_CLASS)
      expect(response.body).not_to include(foreign.id)
    end
  end
end

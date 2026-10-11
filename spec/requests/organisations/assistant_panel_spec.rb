# frozen_string_literal: true

require 'rails_helper'

# S3a T4 (assistant plan §7.1, §7.7, §12): the assistant is a COMPANION LANE,
# not a navigation target. The panel is rendered once into the application
# layout as a data-turbo-permanent node and its body is a lazily loaded turbo
# frame served by AssistantPanelsController.
#
# These specs follow the REQUESTS, because the two things that can go wrong here
# are both request-level:
#
#   1. the panel renders for somebody whose assistant gate is CLOSED (the shell
#      sits in the layout, so a forgotten condition leaks it onto every page),
#   2. the frame endpoint serves a FOREIGN thread (the panel body is the only
#      place the org-wide transcript is rendered from now on).
RSpec.describe 'Assistant companion panel (S3a T4)', type: :request do
  # A usable chat credential is part of the realistic setup: without one the org
  # has no route for a message and the panel says so instead of offering a field
  # (own example below). Real BYOK baseline rather than a stub, so the specs
  # exercise the actual availability chain.
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

  let(:owner)    { member_with_assistant_access }
  let(:stranger) { member_with_assistant_access }

  def thread_for(user, content)
    ActsAsTenant.with_tenant(organisation) do
      chat = create(:chat, :org_thread, organisation: organisation, user: user)
      chat.chatposts.first.update!(user: user, content: content)
      chat
    end
  end

  # ---------------------------------------------------------------------------
  # 1. The layout shell and its gate
  # ---------------------------------------------------------------------------
  describe 'the permanent shell in the application layout' do
    it 'renders the panel and its sidebar row for a member with the assistant pair' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="assistant_panel"')
      expect(response.body).to include('data-turbo-permanent')
      expect(response.body).to include('id="assistant-panel-trigger"')
    end

    # The form the object header's button ends up submitting (Bezugs-Sammlung S1,
    # §8.3). It ships EMPTY on purpose -- the thread it writes to is chosen at
    # click time, because this node is permanent and the server never learns which
    # thread the frame is holding. What the server owes is the base address and
    # the field; anything more here would be a thread id frozen at page load.
    #
    # POST and a bare `key` since S1: adding a reference is a write to a
    # COLLECTION under the thread, and the composite key ("Ticket:<uuid>") is the
    # one value that identifies an entry everywhere (§7.1). The panel appends
    # "/<thread>/references" to the address below.
    it 'ships the context form empty, with the address the panel completes' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      shell = Nokogiri::HTML.fragment(response.body).at_css('#assistant_panel')
      form = shell.at_css('form[data-assistant-panel-target="contextForm"]')
      expect(form).to be_present
      expect(form['action']).to eq(organisation_assistant_chats_path(organisation_id: organisation.id))
      expect(shell['data-assistant-panel-thread-url-value'])
        .to eq(organisation_assistant_chats_path(organisation_id: organisation.id))

      field = form.at_css('[data-assistant-panel-target="contextField"]')
      expect(field['name']).to eq('key')
      expect(field['value']).to eq('')
      # A plain POST, so there is no method override to send: the collection route
      # answers POST directly.
      expect(form.at_css('[name="_method"]')).to be_nil
      # No assertion on the CSRF token: allow_forgery_protection is off in test
      # (config/environments/test.rb:34), so form_with emits none here and an
      # expectation either way would say nothing about production. What carries
      # the request there is the GLOBAL token Turbo sends as X-CSRF-Token on
      # submit; the hidden field's per-form token is bound to the address rendered
      # here and stops matching once the panel rewrites the action -- which is why
      # this form must stay a Turbo submission and not become a fetch().
    end

    # S4 T2 step 5b (§7.3): the strip that offers the page's object. The server
    # owes it EMPTY and hidden -- what it should say is client knowledge (which
    # page you are on, whether a reference already stands), and the server has
    # nothing true to put there when it renders.
    #
    # It ships with the FRAME, not with the shell, since 27.08.2026: it moved up
    # to sit above the reference row it offers to fill, which is inside the chat
    # frame (Neo::Chat::ContextOfferComponent). Own example below for what that
    # costs -- a page that never opens the panel never carries the strip at all.
    #
    # The two lead sentences are both in the markup, one of them hidden, because
    # setting a reference and switching one are different acts and this node is
    # permanent: a sentence patched in by JavaScript could never be corrected by
    # the server. They are also what the take button is DESCRIBED by -- which is
    # a promise the markup has to keep, hence the ids and the role below. The
    # controller only swaps which id the button points at; the text stays here.
    it 'ships the context offer empty, hidden, and with BOTH lead sentences' do
      thread_for(owner, 'Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      offer = Nokogiri::HTML.fragment(response.body).at_css('[data-assistant-panel-target="offer"]')
      expect(offer).to be_present
      expect(offer['class']).to include('hidden')
      expect(offer['data-context-id']).to be_nil

      set_lead = offer.at_css('[data-assistant-panel-target="offerSet"]')
      add_lead = offer.at_css('[data-assistant-panel-target="offerAdd"]')
      expect(set_lead.text.strip).to eq(I18n.t('views.organisations.assistant_panels.offer.set'))
      expect(add_lead.text.strip).to eq(I18n.t('views.organisations.assistant_panels.offer.add'))
      # Only the ADD half starts hidden: a first setting is the common case.
      expect(set_lead['class'].to_s).not_to include('hidden')
      expect(add_lead['class']).to include('hidden')

      expect(offer.at_css('[data-assistant-panel-target="offerLabel"]').text.strip).to eq('')
      expect(offer.css('button').map { |b| b['data-action'] })
        .to contain_exactly('assistant-panel#takeOffer', 'assistant-panel#dismissOffer')

      # The strip appears without anybody asking for it, so it announces itself
      # once. Politely: an offer is not an alert.
      expect(offer['role']).to eq('status')
      # And the ids the button is pointed at are the EXACT ones the controller
      # composes, not merely present. The swap itself lives in
      # assistant_panel_controller.js and CI runs no JavaScript at all
      # (.github/workflows/guards.yml has no spec/system entry), so a rename in
      # this markup would otherwise be caught by nothing in the pipeline: the
      # description would point at ids that no longer exist, the strip would look
      # perfect, and a screen reader would hear "Uebernehmen" and no object.
      # Naming the strings here is what makes that rename go red somewhere.
      expect(set_lead['id']).to eq('assistant_offer_set')
      expect(add_lead['id']).to eq('assistant_offer_add')
      expect(offer.at_css('[data-assistant-panel-target="offerLabel"]')['id'])
        .to eq('assistant_offer_label')
      expect(offer.at_css('[data-assistant-panel-target="offerTake"]')).to be_present
    end

    # Where the strip is NOT. Both halves matter and neither is cosmetic:
    #
    #   * the shell: it used to live there, and a leftover copy would be a second
    #     element carrying assistant_offer_set and friends. The take button is
    #     described BY those ids, so a duplicate is not a tidiness problem, it is
    #     the trap this feature has hit three times (#612) pointed straight at an
    #     accessibility promise.
    #   * a chat page: the offer means "the page you navigated to while the panel
    #     travelled with you". A chat page has no such second surface, and it
    #     renders the very same ChatContainerComponent -- so the guard is the
    #     frame id, and this is what proves it holds.
    it 'keeps the offer OUT of the shell and off a chat page' do
      thread_for(owner, 'Frage')
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(response.body).to include('id="assistant_panel"')
      expect(response.body).not_to include('assistant_offer_set')
      expect(response.body).not_to include('data-assistant-panel-target="offer"')
    end

    it 'renders NOTHING when the operator flag is off' do
      organisation.update!(assistant_enabled: false)
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('id="assistant_panel"')
      expect(response.body).not_to include('id="assistant-panel-trigger"')
    end

    it 'renders NOTHING for a member whose role lacks use_assistant' do
      plain = member_without_assistant_access
      sign_in plain

      get organisation_root_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('id="assistant_panel"')
      expect(response.body).not_to include('id="assistant-panel-trigger"')
    end

    # T4 opened the org-navigation block for the assistant gate, which has
    # nothing to do with reading projects. The search row inside it therefore
    # needed the gate that actually belongs to it — otherwise a user who reached
    # the block only through the assistant would get a search row whose overlay
    # they are not allowed to use.
    it 'shows the assistant row but NOT the search row to a user without project access' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(response.body).to include('id="assistant-panel-trigger"')
      expect(response.body).not_to include('id="global-search-nav"')
    end

    # Consequence of the same gate change, pinned because it is a VISIBLE
    # behaviour change and not one the PR set out to make: a member who reaches
    # the org-navigation block only through the assistant now also sees the inbox
    # row. It is not a leak -- the inbox is that member's own -- but nobody
    # should discover it from a screenshot.
    it 'also brings the inbox row along for an assistant-only member' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(response.body).to include(organisation_notifications_path(organisation_id: organisation.id))
    end

    # The body must NOT be inlined: the shell rides on every page, and rendering
    # a whole transcript per request just to have Turbo throw it away again is
    # the cost this lazy frame exists to avoid.
    it 'ships the body as an EMPTY lazy frame (src is armed by the controller, not the server)' do
      thread_for(owner, 'Wie viele Stunden sind offen?')
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(response.body).to include('id="assistant_panel_body"')
      expect(response.body).not_to include('Wie viele Stunden sind offen?')
    end
  end

  # ---------------------------------------------------------------------------
  # 2. The frame endpoint
  # ---------------------------------------------------------------------------
  describe 'GET /assistant_panel (the frame body)' do
    it 'serves the newest own thread to its owner' do
      thread_for(owner, 'Aeltere Frage')
      thread_for(owner, 'Neueste Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Neueste Frage')
      expect(response.body).not_to include('Aeltere Frage')
    end

    it 'serves the new-thread composer when the user has no thread yet' do
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(organisation_assistant_chats_path(organisation))
    end

    it 'serves the new-thread composer on demand even though a thread exists' do
      thread_for(owner, 'Bestehende Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, new: '1')

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Bestehende Frage')
      expect(response.body).to include(organisation_assistant_chats_path(organisation))
    end

    # §12/§13-10: the address is the dangerous door, so the test uses it directly
    # instead of the convenient path through the interface.
    it 'never serves a FOREIGN thread through a hand-set chat_id' do
      foreign = thread_for(stranger, 'Fremde Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, chat_id: foreign.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Fremde Frage')
    end

    it 'serves an OWN thread through chat_id (the redirect target of a shared link)' do
      own = thread_for(owner, 'Eigene aeltere Frage')
      thread_for(owner, 'Eine neuere Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, chat_id: own.id)

      expect(response.body).to include('Eigene aeltere Frage')
    end

    # Moved here from assistant_chats_spec with T4, because this is where the
    # composer is rendered now. It pins the WRITE access of the surface (T2
    # second review, mutation f): with the org branch of
    # ChatContainerComponent#can_write? broken, the owner got a read-only hint
    # instead of a composer and nothing failed. The form action doubles as the
    # route pin -- the composer must post to the assistant endpoint, never a
    # project one.
    it 'renders a composer posting to the assistant chatposts route' do
      chat = thread_for(owner, 'Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      form_action = organisation_assistant_chat_chatposts_path(organisation, chat)
      expect(Capybara.string(response.body))
        .to have_css("form[action='#{form_action}'] textarea", visible: :all)
    end

    # Found in the browser: the empty state used to render a composer
    # unconditionally, so an org with the AI opt-in on but no usable credential
    # got a field that swallowed the question. The running conversation had
    # always said why (R4); the empty state is now the same branch.
    it 'says WHY instead of offering a field when there is no usable AI route' do
      organisation.update!(ai_access_token: nil)
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(Capybara.string(response.body))
        .to have_no_css("form[action='#{organisation_assistant_chats_path(organisation)}']", visible: :all)
      # The reason itself comes from the feature registry -- pinned here as
      # "something was said", not as one particular sentence.
      expect(response.body).to include('bi-shield-exclamation')
    end

    it 'refuses a member whose role lacks use_assistant' do
      sign_in member_without_assistant_access

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end

    it 'refuses while the operator flag is off' do
      organisation.update!(assistant_enabled: false)
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end

    # The frame is served WITHOUT the application layout. If it ever came back
    # wrapped, the response would carry a second copy of the permanent shell.
    it 'renders WITHOUT the application layout (no second copy of the shell)' do
      thread_for(owner, 'Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response.body).not_to include('id="assistant_panel"')
      expect(response.body).not_to include('id="sidebar"')
    end

    # The panel renders on top of EVERY page, the chat pages included. Sharing
    # the chat frame's id with them would mean two elements with one id in a
    # single document: a citation link's frame escape or any future
    # turbo_stream.replace 'chat-show' (the frame's literal default id,
    # ChatContainerComponent::DEFAULT_FRAME_ID; no stream targets it since S4-T1)
    # would hit whichever comes first in document order. That happens to be the
    # right one today only because the panel is rendered after <main> -- an
    # ordering nobody should have to know about.
    it 'gives its chat frame an id of its own, never the shared "chat-show"' do
      thread_for(owner, 'Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id)

      expect(response.body).to include('id="assistant-panel-chat"')
      expect(response.body).not_to include('id="chat-show"')
    end
  end

  # ---------------------------------------------------------------------------
  # 3. The first message, submitted from inside the panel
  # ---------------------------------------------------------------------------
  describe 'POST /assistant_chats from the panel frame' do
    let(:turbo_headers) do
      { 'Accept' => 'text/vnd.turbo-stream.html', 'Turbo-Frame' => 'assistant_panel_body' }
    end

    before { allow(ChatResponseJob).to receive(:perform_later) }

    # `update`, not `replace`: replacing the frame ELEMENT would drop the src the
    # panel controller armed, and a frame without src can no longer reload itself
    # — which is exactly what the panel does after a transplant swallowed a
    # broadcast. Cheap to pin, invisible when it breaks.
    it 'updates the frame CHILDREN and leaves the frame element in place' do
      sign_in owner

      post organisation_assistant_chats_path(organisation),
           params: { chat: { chatposts_attributes: [{ content: 'Erste Frage' }] } },
           headers: turbo_headers

      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('action="update"')
      expect(response.body).to include('target="assistant_panel_body"')
      expect(response.body).to include('Erste Frage')
    end

    it 'hands a rejected message back into the field instead of swallowing it' do
      sign_in owner

      post organisation_assistant_chats_path(organisation),
           params: { chat: { chatposts_attributes: [{ content: '' }] } },
           headers: turbo_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('target="assistant_panel_body"')
      expect(response.body).to include(organisation_assistant_chats_path(organisation))
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Earlier conversations (S3c T1, plan §7.6)
  # ---------------------------------------------------------------------------
  #
  # Until this ticket the panel served own_threads.FIRST and nothing else, and
  # no surface anywhere linked to a thread: "Neuer Chat" made a new one, which
  # then became the newest, and everything before it was reachable only by
  # somebody who had kept a ?assistant_chat_id= address. The list is the way
  # back in.
  #
  # It is a STATE OF THE PANEL FRAME, like ?new=1 -- not a page and not a second
  # frame. So every link in it has to navigate that frame; a plain link would
  # take the whole page with it and drop the user on the org root.
  describe 'GET /assistant_panel?list=1 (earlier conversations)' do
    it 'lists ALL own threads, not just the newest one' do
      thread_for(owner, 'Aelteste Frage')
      thread_for(owner, 'Mittlere Frage')
      thread_for(owner, 'Neueste Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Aelteste Frage')
      expect(response.body).to include('Mittlere Frage')
      expect(response.body).to include('Neueste Frage')
    end

    it 'newest first (creation order is the honest one, last_message_at is dead)' do
      thread_for(owner, 'Aelteste Frage')
      thread_for(owner, 'Neueste Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response.body.index('Neueste Frage')).to be < response.body.index('Aelteste Frage')
    end

    # The whole point of the surface is "persoenlich ist persoenlich": a list is
    # the one place where a scope slip shows up as a stranger's question in
    # somebody else's panel.
    it 'never lists a FOREIGN thread' do
      thread_for(stranger, 'Fremde Frage')
      thread_for(owner, 'Eigene Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response.body).to include('Eigene Frage')
      expect(response.body).not_to include('Fremde Frage')
    end

    # A row that navigates the PAGE would leave the panel behind and land the
    # user on the org root -- which is exactly what assistant_chats#show does
    # (it redirects), and why the list must not use it.
    it 'points every row at the panel frame, never at a page' do
      chat = thread_for(owner, 'Eine Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      row = Capybara.string(response.body).find(
        "a[href='#{organisation_assistant_panel_path(organisation_id: organisation.id, chat_id: chat.id)}']"
      )
      expect(row['data-turbo-frame']).to eq('assistant_panel_body')
    end

    it 'offers a way back to the running conversation' do
      chat = thread_for(owner, 'Laufende Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', current: chat.id)

      expect(Capybara.string(response.body)).to have_css(
        "a[href='#{organisation_assistant_panel_path(organisation_id: organisation.id, chat_id: chat.id)}']" \
        "[data-turbo-frame='assistant_panel_body']"
      )
    end

    it 'marks the thread that is currently open' do
      open_chat = thread_for(owner, 'Offene Frage')
      thread_for(owner, 'Andere Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', current: open_chat.id)

      expect(Capybara.string(response.body))
        .to have_css("[data-assistant-history-current='true'][data-chat-id='#{open_chat.id}']")
    end

    # ?current= is as client-settable as ?chat_id=, and it is rendered into the
    # markup. A foreign id must not decorate a row -- and above all must not
    # make the list ASK the database about a record the viewer may not see.
    it 'ignores a hand-set foreign current id instead of honouring it' do
      foreign = thread_for(stranger, 'Fremde Frage')
      thread_for(owner, 'Eigene Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', current: foreign.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(foreign.id)
    end

    it 'says so when there is nothing to come back to' do
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        I18n.t('views.organisations.assistant_panels.history.empty')
      )
    end

    # The list is served by the same action as the transcript, so it goes
    # through the same door. Pinned because a new branch in an action is exactly
    # where an authorize call gets forgotten.
    it 'refuses a member whose role lacks use_assistant' do
      sign_in member_without_assistant_access

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end

    it 'refuses while the operator flag is off' do
      organisation.update!(assistant_enabled: false)
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end

    # Same reason as the transcript: rendered without the layout, so it can
    # never carry a second copy of the permanent shell.
    it 'renders WITHOUT the application layout' do
      thread_for(owner, 'Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response.body).not_to include('id="assistant_panel"')
    end

    # The list REPLACES the transcript inside the frame. If it rendered the chat
    # container as well, the panel would carry two elements with the chatposts
    # id and a broadcast would land in whichever came first.
    it 'does not render the chat container alongside the list' do
      thread_for(owner, 'Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1')

      expect(response.body).not_to include('id="assistant-panel-chat"')
    end
  end

  # ---------------------------------------------------------------------------
  # 6. The shell's door to the list
  # ---------------------------------------------------------------------------
  describe 'the history button in the permanent shell' do
    # A LINK cannot carry it: the shell is a permanent node rendered once per
    # page, and it never knows which thread the frame is showing. The button
    # asks the controller, which reads the open thread off the frame.
    it 'is a button driven by the panel controller, not a bare link' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(Capybara.string(response.body))
        .to have_css("button[data-action='assistant-panel#showHistory']", visible: :all)
    end
  end

  # ---------------------------------------------------------------------------
  # 6b. The shell's door to the settings
  # ---------------------------------------------------------------------------
  describe 'the settings button in the permanent shell' do
    # Same reason the history button above is a button: the way BACK out of the
    # settings has to land on the conversation the gear was pressed on, and only
    # the browser knows which one that is. A link would return to the panel
    # default, i.e. the newest thread.
    it 'is a button driven by the panel controller, not a bare link' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      expect(Capybara.string(response.body))
        .to have_css("button[data-action='assistant-panel#showSettings']", visible: :all)
    end

    it 'carries the gear icon and an accessible name' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      button = Capybara.string(response.body).find("button[data-action='assistant-panel#showSettings']", visible: :all)
      expect(button['aria-label']).to eq(I18n.t('views.organisations.assistant_panels.settings.open'))
      expect(button).to have_css('i.bi-gear', visible: :all)
    end

    # The gate is the shell's, not the button's: somebody without the assistant
    # never sees the panel at all, so a settings door inside it must not be the
    # one thing that leaks.
    it 'is absent for somebody whose assistant gate is closed' do
      sign_in member_without_assistant_access

      get organisation_root_path(organisation_id: organisation.id)

      expect(Capybara.string(response.body))
        .to have_no_css("button[data-action='assistant-panel#showSettings']", visible: :all)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. The full view (S3c T2, plan §4/L11)
  # ---------------------------------------------------------------------------
  #
  # The third state of the SAME chat: a class on the same permanent node, never a
  # second page. What the server owes it is the FIRST PAINT — the cookie carries
  # the mode, so a hard reload has to land maximised instead of jumping once the
  # controller connects.
  describe 'the shell in the full view' do
    # Sent as a request header rather than through `cookies`: the jar does not
    # exist before the first request, and what is under test here is exactly what
    # the server does with a cookie it finds on the WAY IN.
    def panel_cookie(value)
      { 'Cookie' => "#{AssistantPanelState::COOKIE_NAME}=#{value}" }
    end

    it 'offers both directions as separate buttons, each with its own name' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id)

      page = Capybara.string(response.body)
      expect(page).to have_css("button[data-action='assistant-panel#expandToFull']", visible: :all)
      expect(page).to have_css("button[data-action='assistant-panel#collapseToPanel']", visible: :all)
    end

    it 'paints the full view server-side when the cookie says so' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id),
          headers: panel_cookie('1:420:full')

      expect(response.body).to include('assistant-panel--full')
      expect(response.body).to include('assistant-panel-full')
    end

    it 'stays the companion panel for a cookie without a mode' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id),
          headers: panel_cookie('1:420')

      expect(response.body).not_to include('assistant-panel--full')
    end

    # The offset moves the page aside for a panel STANDING NEXT to it. In the
    # full view the page is covered, so an offset would shove something nobody
    # can see and leave the gap behind on the way back down.
    it 'publishes NO content offset in the full view' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id),
          headers: panel_cookie('1:420:full')

      expect(response.body).not_to include('--assistant-panel-offset')
    end

    it 'publishes the offset in companion mode' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id),
          headers: panel_cookie('1:420')

      expect(response.body).to include("--assistant-panel-offset: #{AssistantPanelState::SIDEBAR_WIDTH + 420}px")
    end

    # The width belongs to the layout up there (§7.7), and an inline style would
    # outrank the class that hands it over.
    it 'renders no inline width in the full view' do
      sign_in owner

      get organisation_root_path(organisation_id: organisation.id),
          headers: panel_cookie('1:420:full')

      expect(response.body).not_to include('width: 420px')
    end
  end

  # ---------------------------------------------------------------------------
  # 8. The history LANE (the same list, the other surface)
  # ---------------------------------------------------------------------------
  describe 'GET /assistant_panel?list=1&lane=1' do
    it 'answers into the lane frame, not into the chat frame' do
      thread_for(owner, 'Eine Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', lane: '1')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="assistant_panel_history"')
      expect(response.body).not_to include('id="assistant_panel_body"')
    end

    # In the lane the conversation is right there beside the list. An arrow
    # pointing at what is already visible is noise.
    it 'has no way back, because it did not take anything away' do
      chat = thread_for(owner, 'Eine Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', lane: '1', current: chat.id)

      expect(Capybara.string(response.body)).to have_no_css(
        "a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']"
      )
    end

    it 'still refuses to show a FOREIGN thread' do
      thread_for(stranger, 'Fremde Frage')
      thread_for(owner, 'Eigene Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', lane: '1')

      expect(response.body).to include('Eigene Frage')
      expect(response.body).not_to include('Fremde Frage')
    end

    # Rows navigate the CHAT frame from here as well: clicking a thread in the
    # lane must exchange the conversation next to it, not the lane itself.
    it 'points its rows at the chat frame, so the lane stays put' do
      chat = thread_for(owner, 'Eine Frage')
      sign_in owner

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', lane: '1')

      row = Capybara.string(response.body).find("a[data-chat-id='#{chat.id}']")
      expect(row['data-turbo-frame']).to eq('assistant_panel_body')
    end

    # NO twin of the overlay's "ignores a hand-set foreign current id" here, and
    # that is a finding rather than an omission: written, it was green with the
    # resolution mutated to a bare Chat.find_by, because this surface has no exit
    # that prints the id. The overlay does -- its back arrow builds an href from
    # @current_chat -- and its test is the one that bites. Marking cannot leak it
    # either: current?(chat) is asked about the rows, and those are own_threads.
    #
    # ⚠️ The day the lane grows an exit that renders @current_chat (a back link, a
    # heading naming the open thread), it needs this test for real. See the note
    # on requested_current_thread in the controller.

    it 'goes through the same door as everything else here' do
      sign_in member_without_assistant_access

      get organisation_assistant_panel_path(organisation_id: organisation.id, list: '1', lane: '1')

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # 9. The shareable address (S3c T2, §7.5/L3)
  # ---------------------------------------------------------------------------
  describe 'GET /assistant' do
    it 'hands the full view over through the address and lands on a real page' do
      sign_in owner

      get organisation_assistant_path(organisation_id: organisation.id)

      expect(response).to redirect_to(
        organisation_root_path(organisation_id: organisation.id, assistant: AssistantPanelState::MODE_FULL)
      )
    end

    # Same door as the panel itself. A shareable link is exactly the thing that
    # reaches somebody the gate was never opened for.
    it 'refuses a member whose role lacks use_assistant' do
      sign_in member_without_assistant_access

      get organisation_assistant_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:redirect)
      expect(response).not_to redirect_to(
        organisation_root_path(organisation_id: organisation.id, assistant: AssistantPanelState::MODE_FULL)
      )
      expect(flash[:alert]).to be_present
    end

    it 'refuses while the operator flag is off' do
      organisation.update!(assistant_enabled: false)
      sign_in owner

      get organisation_assistant_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # 4. There is no second place (L11)
  # ---------------------------------------------------------------------------
  describe 'GET /assistant_chats/:id (no longer a page of its own)' do
    it 'hands the thread to the panel instead of rendering a second chat surface' do
      chat = thread_for(owner, 'Wie viele Stunden sind offen?')
      sign_in owner

      get organisation_assistant_chat_path(organisation, chat)

      expect(response).to redirect_to(
        organisation_root_path(organisation_id: organisation.id, assistant_chat_id: chat.id)
      )
    end

    it 'keeps the owner door: a colleague still gets the made-up-id answer' do
      chat = thread_for(owner, 'Wie viele Stunden sind offen?')
      sign_in stranger

      get organisation_assistant_chat_path(organisation, chat)

      expect(response).to have_http_status(:not_found)
    end
  end
end

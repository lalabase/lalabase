# frozen_string_literal: true

require 'rails_helper'

# S3a T4 (assistant plan §7.7): the claims of the companion panel that only a
# BROWSER can settle. The request specs cover who may see it and what the frame
# serves; everything here is behaviour that lives in
# assistant_panel_controller.js and would be vacuum-green anywhere else:
#
#   * the panel is a data-turbo-permanent node, so a Turbo visit must leave the
#     typed draft and the loaded transcript standing,
#   * the body is fetched LAZILY -- never on a page that nobody opened the panel
#     on,
#   * the content offset is handed to the INCOMING body, so the page after a
#     navigation is already shifted.
#
# NOTE: the system driver disables CSS, so everything is asserted on classes,
# attributes and inline styles -- the same approach as global_search_overlay_spec.
RSpec.describe 'Assistant companion panel', type: :system do
  # Bezugs-Sammlung S1: the reference stopped being a column and became the
  # scope_references list, so every "did it reach the database" check reads the
  # ids out of that list. Same claim, different address.
  def reference_ids_of(chat)
    ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_references }.map { |entry| entry['id'] }
  end

  before { Prosopite.pause }
  after  { Prosopite.resume }

  # With no usable chat credential the panel correctly shows the reason instead
  # of a composer, and half of these examples are about the composer.
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:admin_role, organisation: organisation)
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    visit organisation_root_path(organisation_id: organisation.id)
  end

  def panel_root  = page.find('#assistant_panel', visible: :all)
  def panel       = page.find('[data-assistant-panel-target="panel"]', visible: :all)
  def capsule     = page.find('[data-assistant-panel-target="capsule"]', visible: :all)
  def frame       = page.find('#assistant_panel_body', visible: :all)
  # The offset is a custom property on <body>, not an inline margin on <main>:
  # whether it APPLIES is a viewport question and lives in a media query. The
  # system driver disables CSS, so the property is what can be asserted here --
  # and it is also the single value both writers (server and controller) set.
  def main_offset = page.evaluate_script('document.body.style.getPropertyValue("--assistant-panel-offset")')
  def body_class  = page.evaluate_script('document.body.className')

  def open_panel
    find('#assistant-panel-trigger').click
    expect(panel[:class]).not_to include('hidden')
  end

  # The context offer (S4 T2 step 5b). visible: :all like everything else here --
  # the driver runs without CSS, so `hidden` is a class to read, never a state to
  # see.
  #
  # Since 27.08.2026 the strip ships with the chat FRAME rather than the panel
  # shell (Neo::Chat::ContextOfferComponent), so "no offer" now has two shapes:
  # rendered and carrying `hidden`, or not rendered at all on history/settings. #no_offer? answers the question both states answer,
  # which is the question every caller was really asking.
  def offer             = page.find('[data-assistant-panel-target="offer"]', visible: :all)
  def offer?            = page.has_css?('[data-assistant-panel-target="offer"]', visible: :all, wait: 0)
  def no_offer?         = !offer? || offer[:class].include?('hidden')
  def offer_lead_set    = page.find('[data-assistant-panel-target="offerSet"]', visible: :all)
  def offer_lead_add = page.find('[data-assistant-panel-target="offerAdd"]', visible: :all)
  def offer_label       = page.find('[data-assistant-panel-target="offerLabel"]', visible: :all)
  def offer_take        = page.find('[data-assistant-panel-target="offerTake"]', visible: :all)
  # Bezugs-Sammlung S1: the offer remembers the composite KEY of §7.1, not a bare
  # id -- the collection is addressed by the pair everywhere, and a bare id would
  # make a meeting and a ticket sharing one look like the same object. The helper
  # takes a record so every call site keeps reading like a sentence.
  def offered_context   = offer['data-context-id']
  def offering?(record) = offered_context == "#{record.class.name}:#{record.id}"

  # A real Turbo visit, i.e. what a link click does: the permanent node is
  # transplanted and the loaded transcript comes along. Capybara's own `visit` is
  # a browser load, which throws the JS context away -- a different path, and one
  # the cold first step already covers.
  def turbo_visit(path)
    page.execute_script("Turbo.visit('#{path}')")
  end

  # What a click on a row in the ticket list does: it arms #ticket_display_frame
  # and lets Turbo fetch (ticket_row_controller.js:93). No navigation, no
  # transplant of the permanent node -- which is exactly the case the panel's
  # document-level turbo:frame-load listener exists for.
  # Waits for the PAGE, not for the strip. Every "the offer stays away" assertion
  # needs this in front of it: without it `offered_context.nil?` is already true
  # before the navigation lands, and the example is green before anything has
  # happened. Measured, not feared -- step 7 was exactly that until a mutation
  # probe on the missing-thread guard came back green.
  def await_page_context(ticket)
    eventually("the page for ##{ticket.number} arrived and named its object") do
      page.has_css?("[data-assistant-context='#{ticket.id}']", visible: :all, wait: 0)
    end
  end

  # A server round trip AFTER the thing under test, as a barrier. Without one,
  # "nothing was written" is green because nothing has ARRIVED yet: the check runs
  # while a write could still be in flight.
  #
  # ⚠️ NOT the history lane, which is what the first version of this used. That
  # button loads the conversation LIST into the chat frame, which takes the
  # transcript off screen -- openThreadId then answers nil, the offer withdraws
  # for a perfectly good reason, and every step after the barrier is standing in
  # a state the example never asked for. A barrier that changes the thing it is
  # measuring is not a barrier. A bare fetch touches nothing.
  def await_round_trip
    page.execute_script(<<~JS)
      window.__roundTrip = false
      fetch(window.location.pathname, { headers: { Accept: 'text/html' } })
        .then(() => { window.__roundTrip = true })
        .catch(() => { window.__roundTrip = true })
    JS
    eventually('a later request came back, so an earlier one would have too') do
      page.evaluate_script('window.__roundTrip === true')
    end
  end

  # Both halves of what list_row_controller#click does: the frame exchange AND
  # opening the lane (showContent). The second half matters since the knowledge
  # objects joined the assistant (doc/assistent_wissen_kontext_plan.md): the
  # panel ignores a marker inside a CLOSED lane (.layout.hide-content), because
  # the ✕ hides the column by class and leaves the markup standing. A frame
  # exchanged into a lane nobody opened is exactly that state.
  def show_in_ticket_frame(path)
    page.execute_script(<<~JS)
      document.getElementById('ticket_display_frame').setAttribute('src', '#{path}?frame=content')
      const grid = document.querySelector('[data-controller~="layout-toggle"]')
      window.Stimulus?.getControllerForElementAndIdentifier(grid, 'layout-toggle')?.showContent()
    JS
  end

  def composer_value
    page.evaluate_script(
      %{document.querySelector('#assistant_panel [data-neo-chat-composer-target="field"]')?.value}
    )
  end

  # evaluate_script does not retry, and the panel body arrives over the network:
  # on the first open the composer is still in flight. Poll like Capybara would.
  # Poll like Capybara does, for conditions Capybara has no matcher for.
  def eventually(description)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until yield
    end
  rescue Timeout::Error
    raise "never became true: #{description}"
  end

  def expect_composer_value(expected)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until composer_value == expected
    end
  rescue Timeout::Error
    raise "composer still held #{composer_value.inspect}, expected #{expected.inspect}"
  end

  it 'starts closed, with the capsule standing in for it and NO body request made' do
    expect(panel[:class]).to include('hidden')
    expect(capsule[:class]).not_to include('hidden')
    # The lazy frame: no src means the transcript was never fetched.
    expect(frame[:src]).to be_blank
    expect(main_offset).to be_blank
  end

  it 'opens from the sidebar row, shifts the content and loads the body once' do
    open_panel

    expect(capsule[:class]).to include('hidden')
    expect(frame[:src]).to be_present
    expect(main_offset).to eq("#{AssistantPanelState::SIDEBAR_WIDTH + AssistantPanelState::DEFAULT_WIDTH}px")
    expect(body_class).to include('assistant-panel-open')
  end

  it 'opens and closes with Cmd/Ctrl+J from anywhere on the page' do
    find('body').send_keys([:control, 'j'])
    expect(panel[:class]).not_to include('hidden')

    find('body').send_keys([:control, 'j'])
    expect(panel[:class]).to include('hidden')
    expect(main_offset).to be_blank
  end

  it 'closes again from the panel header' do
    open_panel

    find('[data-action="assistant-panel#close"]').click

    expect(panel[:class]).to include('hidden')
    expect(capsule[:class]).not_to include('hidden')
    expect(body_class).not_to include('assistant-panel-open')
  end

  # The offset has to reach the INCOMING body, not the one already on screen:
  # applying it afterwards replays the 500ms transition on every navigation.
  #
  # The cookie is dropped first, and that is the whole point of the example. With
  # it in place the SERVER already renders the class and the property onto every
  # page, so the incoming body carries them whether or not the hook exists -- a
  # first version of this example passed with the hook deleted. Without the
  # cookie (a browser that refuses it, private mode) the hook is the only thing
  # left, and that is the case worth pinning.
  it 'hands the offset to the incoming body BEFORE it is rendered, cookie or no cookie' do
    open_panel
    page.execute_script('document.cookie = "assistant_panel=; Max-Age=0; path=/"')

    page.execute_script(<<~JS)
      window.__incoming = null
      document.addEventListener("turbo:before-render", (event) => {
        window.__incoming = {
          klass: event.detail.newBody.classList.contains("assistant-panel-open"),
          offset: event.detail.newBody.style.getPropertyValue("--assistant-panel-offset"),
        }
      }, { once: true })
    JS
    page.execute_script("Turbo.visit('#{organisation_appearance_path(organisation)}')")
    expect(page).to have_current_path(organisation_appearance_path(organisation), ignore_query: true)

    incoming = page.evaluate_script('window.__incoming')
    expect(incoming).not_to be_nil
    expect(incoming['klass']).to be(true)
    expect(incoming['offset']).to be_present
  end

  # THE point of the whole design (L11/§7.7). Without data-turbo-permanent the
  # node is re-rendered from the server on every visit and the draft is gone --
  # which is precisely the papercut the companion lane exists to remove.
  it 'survives a Turbo navigation with the typed draft and the open state intact' do
    open_panel
    expect(frame).to have_css('[data-neo-chat-composer-target="field"]', visible: :all)

    page.execute_script(<<~JS)
      const field = document.querySelector('#assistant_panel [data-neo-chat-composer-target="field"]')
      field.value = 'Ein halb getippter Satz'
      document.querySelector('#assistant_panel').dataset.probe = 'same-node'
    JS

    page.execute_script("Turbo.visit('#{organisation_appearance_path(organisation)}')")
    expect(page).to have_current_path(organisation_appearance_path(organisation), ignore_query: true)

    # Same NODE, not a re-render that happens to look alike.
    expect(panel_root['data-probe']).to eq('same-node')
    expect(panel[:class]).not_to include('hidden')
    expect(main_offset).to be_present
    expect(composer_value).to eq('Ein halb getippter Satz')
  end

  # The global listeners (Cmd+J, the sidebar event, the scroll capture) are
  # registered ONCE and guarded on the controller instance. If a transplant ever
  # produced a second registration, Cmd+J would toggle twice per press and the
  # panel would flicker shut again — which looks like "the shortcut is broken",
  # not like "a listener is doubled".
  it 'keeps exactly ONE keyboard listener across a Turbo navigation' do
    page.execute_script("Turbo.visit('#{organisation_appearance_path(organisation)}')")
    expect(page).to have_current_path(organisation_appearance_path(organisation), ignore_query: true)

    find('body').send_keys([:control, 'j'])

    expect(panel[:class]).not_to include('hidden')
  end

  # The capsule is a SEND field, not a hand-over field (26.08.2026). It used to fill
  # the composer and then wait for a second trigger, which reads as a swallowed
  # question: the panel opens, the sentence sits in the field, nothing happens.
  it 'unfolds from the capsule and sends the typed question right away' do
    allow(ChatResponseJob).to receive(:perform_later)
    capsule_input = find('[data-assistant-panel-target="capsuleInput"]', visible: :all)
    capsule_input.send_keys('Wie viele Stunden sind offen?', :enter)

    expect(panel[:class]).not_to include('hidden')
    # Both halves of "it was actually sent": the question stands in the transcript,
    # and the field it travelled through is empty again.
    expect(page).to have_css('#assistant_panel_body', text: 'Wie viele Stunden sind offen?')
    expect_composer_value('')
  end

  # The one case where the capsule must NOT send. Appending to a half-written
  # sentence and firing would post somebody's draft along with the new question,
  # and a draft is the one thing this panel promises to keep (permanent node).
  it 'appends to a standing draft instead of sending it' do
    allow(ChatResponseJob).to receive(:perform_later)
    open_panel
    eventually('the composer arrived') { !composer_value.nil? }
    page.execute_script(
      %{const f = document.querySelector('#assistant_panel [data-neo-chat-composer-target="field"]');
        f.value = 'Ein halb getippter Satz'; f.dispatchEvent(new Event('input', { bubbles: true }))}
    )
    expect_composer_value('Ein halb getippter Satz')

    find('#assistant_panel button[data-action="assistant-panel#close"]').click
    expect(capsule[:class]).not_to include('hidden')

    find('[data-assistant-panel-target="capsuleInput"]', visible: :all)
      .send_keys('Zweite Frage', :enter)

    expect_composer_value("Ein halb getippter Satz\nZweite Frage")
    # Server-side truth, not the absence of a string on screen: nothing was posted.
    expect(Chat.where(organisation: organisation).count).to eq(0)
  end

  # The seam between the two rules above. "Is there a draft" and "what do we
  # append to" have to be the SAME question, or a composer holding nothing but a
  # stray space falls between them: it counts as no draft (so the question fires,
  # correctly) while still being truthy enough to prepend, and a blank first line
  # rides along into the posted message.
  it 'treats a whitespace-only composer as no draft and sends without a blank first line' do
    allow(ChatResponseJob).to receive(:perform_later)
    open_panel
    eventually('the composer arrived') { !composer_value.nil? }
    page.execute_script(
      %{const f = document.querySelector('#assistant_panel [data-neo-chat-composer-target="field"]');
        f.value = '   '; f.dispatchEvent(new Event('input', { bubbles: true }))}
    )

    find('#assistant_panel button[data-action="assistant-panel#close"]').click
    expect(capsule[:class]).not_to include('hidden')

    find('[data-assistant-panel-target="capsuleInput"]', visible: :all)
      .send_keys('Wie viele Stunden sind offen?', :enter)

    expect(page).to have_css('#assistant_panel_body', text: 'Wie viele Stunden sind offen?')
    expect_composer_value('')
    # What was STORED, not what is on screen: the space must not have travelled.
    chat = Chat.where(organisation: organisation).last
    expect(chat).to be_present
    expect(chat.chatposts.first.content).to eq('Wie viele Stunden sind offen?')
  end

  # The MIDDLE of the seam. Both ends were pinned (assistant_chats#show redirects
  # with ?assistant_chat_id=, and the panel endpoint honours a chat_id), but not
  # that the two actually meet -- and they only meet through JavaScript, because
  # a permanent node never sees server-rendered markup. "A shared link opens that
  # conversation" is a promise of this slice; without this example nothing fires it.
  it 'opens the thread a shared assistant_chats link points at' do
    older = ActsAsTenant.with_tenant(organisation) do
      chat = create(:chat, :org_thread, organisation: organisation, user: user)
      chat.chatposts.first.update!(user: user, content: 'Die geteilte Frage')
      chat
    end
    ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: user)
        .chatposts.first.update!(user: user, content: 'Eine neuere Frage')
    end

    visit organisation_assistant_chat_path(organisation, older)

    expect(panel[:class]).not_to include('hidden')
    expect(page).to have_css('#assistant_panel_body', text: 'Die geteilte Frage')
    expect(page).to have_no_css('#assistant_panel_body', text: 'Eine neuere Frage')
  end

  # "Neuer Chat" is a LINK that navigates the frame, so Turbo points the frame's
  # src at ?new=1. assistant_chats#create then fills the frame with a real
  # conversation through an `update`, which deliberately does not touch src --
  # so the panel is left holding an address that answers "empty". The next time
  # anything re-fetches (the transplant resync, which fires precisely because an
  # answer is outstanding), the just-asked question vanishes from the panel.
  #
  # Reproduced in the browser before the fix; the whole path only exists in
  # JavaScript, so nothing below the system level can see it.
  it 'keeps a freshly started conversation across a navigation' do
    allow(ChatResponseJob).to receive(:perform_later)
    open_panel
    find("#assistant_panel a[href*='new=1']").click
    expect(page).to have_css('#assistant_panel_body [data-neo-chat-composer-target="field"]', visible: :all)

    page.execute_script(<<~JS)
      const field = document.querySelector('#assistant_panel [data-neo-chat-composer-target="field"]')
      field.value = 'Meine erste Frage'
      field.form.requestSubmit()
    JS
    expect(page).to have_css('#assistant_panel_body', text: 'Meine erste Frage')

    # Sync point, not a sleep: the transplant resync re-fetches the frame exactly
    # once (with the fix by pointing src somewhere else, without it by reloading
    # the same address), so waiting for ONE frame load puts the assertion after
    # the fetch either way. Asserting right after the visit passed in both cases
    # -- the content was still the old DOM -- which made the first version of
    # this example vacuum-green: the mutation probe did not bite.
    page.execute_script(<<~JS)
      window.__panelFrameLoads = 0
      document.addEventListener("turbo:frame-load", (e) => {
        if (e.target.id === "assistant_panel_body") window.__panelFrameLoads += 1
      })
    JS
    page.execute_script("Turbo.visit('#{organisation_appearance_path(organisation)}')")
    expect(page).to have_current_path(organisation_appearance_path(organisation), ignore_query: true)
    eventually('the panel re-fetched its body once') { page.evaluate_script('window.__panelFrameLoads') >= 1 }

    expect(page).to have_css('#assistant_panel_body', text: 'Meine erste Frage')
  end

  it 'gives the focus back when it closes, instead of dropping it on the body' do
    find('#assistant-panel-trigger').click
    expect(panel[:class]).not_to include('hidden')

    find('[data-action="assistant-panel#close"]').click

    expect(page.evaluate_script('document.activeElement.id')).to eq('assistant-panel-trigger')
  end

  it 'closes on Escape from inside the panel' do
    open_panel
    # From the composer, which is where the focus actually is after opening; the
    # keydown bubbles to the panel, where the action sits. A div is not focusable,
    # so sending the key to the panel itself would prove nothing.
    expect(page).to have_css('#assistant_panel [data-neo-chat-composer-target="field"]', visible: :all)

    page.find('#assistant_panel [data-neo-chat-composer-target="field"]', visible: :all).send_keys(:escape)

    expect(panel[:class]).to include('hidden')
  end

  # S3a T5: the scope chip. A select with auto-submit into the panel frame -- no
  # controller of its own, but three parts that have to meet (form target, the
  # PATCH route, the turbo_stream that re-renders just the chip), and none of
  # them is visible to a request spec.
  it 'narrows the thread through the scope chip and keeps the choice' do
    project = ActsAsTenant.with_tenant(organisation) do
      # TWO projects: the chip only renders where there is something to choose
      # between, so a single-project organisation would not show it at all.
      create(:project, organisation: organisation, name: 'Kundenportal v2')
      create(:project, organisation: organisation, name: 'Nordlicht Software')
    end
    chat = ActsAsTenant.with_tenant(organisation) do
      thread = create(:chat, :org_thread, organisation: organisation, user: user)
      thread.chatposts.first.update!(user: user, content: 'Erste Frage')
      thread
    end

    open_panel
    expect(page).to have_css('#assistant_panel select[name="chat[scope_project_id]"]', visible: :all)

    # Record the stream the server sends back. Asserting the select's VALUE would
    # prove nothing: the browser already holds the value the user just picked, so
    # that assertion passes even with the turbo_stream aimed at a target that does
    # not exist -- the mutation probe caught exactly that. What is worth pinning
    # is that the server's answer REACHED the chip, because the chip renders the
    # RESOLVED selection (a project archived in the meantime comes back as "all"),
    # and that only works if the stream finds its target.
    page.execute_script(<<~JS)
      window.__chipStreams = []
      document.addEventListener("turbo:before-stream-render", (event) => {
        window.__chipStreams.push(event.target.getAttribute("target"))
      })
    JS

    page.find('#assistant_panel select[name="chat[scope_project_id]"]', visible: :all)
        .select('Nordlicht Software')

    eventually('the choice reached the database') do
      ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_project_id } == project.id
    end
    eventually('the server re-rendered the chip row') do
      page.evaluate_script('window.__chipStreams').include?("chat_#{chat.id}_scope_row")
    end
  end

  # S4 T2 step 5 (§7.3): the whole way, from the button in a ticket header to the
  # chip under the composer. Nothing else can settle it -- three separate pieces
  # have to meet in a browser, and each is green on its own without the path
  # working: the window event over the seam, the panel picking the thread it
  # happens to be showing, and the server refusing or storing the reference.
  #
  # Deliberately started from the TICKET page, not from the dashboard: the button
  # only exists there, and the panel is a permanent node that has to survive the
  # visit to get the click at all.
  it 'takes over the ticket the page is about, from the button to the chip' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht') }
    ticket = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Anmeldung schlaegt fehl')
    end
    chat = ActsAsTenant.with_tenant(organisation) do
      thread = create(:chat, :org_thread, organisation: organisation, user: user)
      thread.chatposts.first.update!(user: user, content: 'Erste Frage')
      thread
    end

    visit organisation_project_ticket_path(organisation, project, ticket)
    find("[data-assistant-trigger-id-value='#{ticket.id}']").click

    # The write landed on the thread the panel was showing, and it carried NOTHING
    # else with it. Until S2 it also wrote the ticket's project into the scope
    # chip; E3 (Bezugs-Sammlung §2.2) ended that, and this is the browser-level
    # statement of it: a button labelled "Assistent" does not silently re-point
    # where the assistant searches.
    eventually('the reference reached the database') do
      reference_ids_of(chat) == [ticket.id]
    end
    expect(ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_project_id }).to be_nil

    # And the chip is on screen, because opening the panel is part of the act:
    # a reference set out of sight is exactly what §7.3 forbids.
    expect(panel[:class]).not_to include('hidden')
    expect(page).to have_css(
      "##{ActionView::RecordIdentifier.dom_id(chat)}_reference_chip", visible: :all
    )
    expect(page.find("##{ActionView::RecordIdentifier.dom_id(chat)}_reference_chip", visible: :all).text)
      .to include("##{ticket.number} Anmeldung schlaegt fehl")

    # And back out again, through the chip's own button. The x takes the reference
    # and nothing else: since E3 the scope chip is the user's own setting, and a
    # removal that cleared it would throw away a choice this button never made.
    ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).update!(scope_project: project) }
    page.find("##{ActionView::RecordIdentifier.dom_id(chat)}_reference_chip button", visible: :all).click

    eventually('the reference was taken back off the thread') do
      reference_ids_of(chat).empty?
    end
    expect(ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_project_id }).to eq(project.id)
  end

  # S4 T2 step 5b (§7.3): "the panel MAY offer the new page context as a takeable
  # chip", and it never takes it over silently. Only a browser can settle this --
  # every piece is green on its own without the path working: the page's marker,
  # the search that finds it after a navigation, the comparison against the chip
  # the server rendered last, and the refusal that survives being re-asked.
  #
  # It runs the WHOLE arc in one example on purpose. The interesting states are
  # sequential -- an offer becomes a switch only because the previous offer was
  # taken, and a refusal can only be shown to hold by asking again afterwards.
  # Split into separate examples, each would have to rebuild the state before it
  # by driving the same clicks anyway.
  #
  # Three tickets, because two cannot tell the reasons for silence apart: the one
  # that was taken is already the reference, so it would go quiet for a reason
  # that has nothing to do with a refusal.
  it 'takes references before the first message, preserves a draft, and sends them with the first answer' do
    project = create(:project, organisation: organisation)
    first = create(:ticket, project: project, organisation: organisation, creator: user, title: 'Erster Bezug')
    second = create(:ticket, project: project, organisation: organisation, creator: user, title: 'Zweiter Bezug')
    open_panel
    turbo_visit(organisation_project_ticket_path(organisation, project, first))
    eventually('a first-ever conversation offers its page') { offering?(first) }
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)
    offer_take.click
    expect(page).to have_css('[data-draft-label]', text: 'Erster Bezug')
    expect(no_offer?).to be true
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)

    turbo_visit(organisation_project_ticket_path(organisation, project, second))
    eventually('navigation offers another reference') { offering?(second) }
    expect(page).to have_css('[data-draft-label]', text: 'Erster Bezug')
    offer_take.click
    expect(page).to have_css('[data-draft-reference]', count: 2)
    find('[data-draft-reference]', text: 'Zweiter Bezug').find('button').click
    expect(page).to have_css('[data-draft-reference]', count: 1)
    eventually('removing a draft reference offers it again') { offering?(second) }

    # Turbo has already captured FormData when submit-start fires. The visible
    # selection must stay fixed until that request finishes, including direct adoption.
    page.execute_script(<<~JS)
      const form = document.querySelector('[data-assistant-panel-target=draftReferences]').closest('form')
      form.dispatchEvent(new Event('turbo:submit-start', { bubbles: true }))
      window.dispatchEvent(new CustomEvent('assistant-panel:adopt', {
        detail: { referenceKey: 'Ticket:#{second.id}' }
      }))
    JS
    expect(page).to have_css('[data-draft-reference] button[disabled]')
    expect(no_offer?).to be true
    expect(page).to have_css('[data-draft-reference]', count: 1)
    page.execute_script(<<~JS)
      document.querySelector('[data-assistant-panel-target=draftReferences]').closest('form')
        .dispatchEvent(new Event('turbo:submit-end', { bubbles: true }))
    JS
    expect(page).to have_no_css('[data-draft-reference] button[disabled]')
    eventually('the offer returns after submission') { offering?(second) }

    # Blank submit forces a server re-render without an AI job.
    page.execute_script("document.querySelector('[data-assistant-panel-target=draftReferences]').closest('form').requestSubmit()")
    eventually('failed submit re-rendered the selected reference') do
      page.has_css?('[data-draft-label]', text: 'Erster Bezug') &&
        page.has_css?('#assistant_panel_body .text-red-700')
    end
    # Hold the real Turbo Stream response body after its headers have arrived.
    # submit-end fires in this window; neither a second Enter nor a reference
    # edit may change the selection already saved for the first answer.
    page.execute_script(<<~JS)
      window.assistantDraftPosts = 0
      document.addEventListener('turbo:before-fetch-request', (event) => {
        if (event.target.matches('form[action$="/assistant_chats"]')) window.assistantDraftPosts++
      })
      document.addEventListener('turbo:before-fetch-response', (event) => {
        if (!event.target.matches('form[action$="/assistant_chats"]')) return
        const response = event.detail.fetchResponse
        const body = response.responseHTML
        const delayed = new Promise((resolve) => {
          window.releaseAssistantResponse = () => body.then(resolve)
        })
        Object.defineProperty(response, 'responseHTML', { get: () => delayed })
      }, { capture: true })
    JS
    field = find('#assistant_panel [data-neo-chat-composer-target="field"]')
    field.set('Fasse den ersten Bezug zusammen.')
    field.send_keys(:enter)
    eventually('the real response body is held') do
      page.evaluate_script('typeof window.releaseAssistantResponse === "function"')
    end
    expect(page).to have_css('[data-draft-reference] button[disabled]')
    expect(no_offer?).to be true
    field.send_keys(:enter)
    expect(page.evaluate_script('window.assistantDraftPosts')).to eq(1)
    page.execute_script('window.releaseAssistantResponse()')
    expect(page).to have_css('#assistant-panel-chat')
    chat = ActsAsTenant.with_tenant(organisation) { Chat.last }
    expect(chat.scope_references).to eq([{ 'type' => 'Ticket', 'id' => first.id }])
    expect(chat.chatposts.first.content).to eq('Fasse den ersten Bezug zusammen.')
    expect(page).to have_no_css('[data-assistant-panel-target="draftReferences"]')
    expect(ChatResponseJob).to have_received(:perform_later).with(chat, question_chatpost_id: chat.chatposts.first.id)
    eventually('the running conversation offers the other page immediately') { offering?(second) }
  end

  it 'offers the page object, switches, and stays refused until the tab is reloaded' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht') }
    taken, refused, control = ActsAsTenant.with_tenant(organisation) do
      [create(:ticket, project: project, organisation: organisation, creator: user, title: 'Anmeldung schlaegt fehl'),
       create(:ticket, project: project, organisation: organisation, creator: user, title: 'Export bricht ab'),
       create(:ticket, project: project, organisation: organisation, creator: user, title: 'Suche findet nichts')]
    end
    chat = ActsAsTenant.with_tenant(organisation) do
      thread = create(:chat, :org_thread, organisation: organisation, user: user)
      thread.chatposts.first.update!(user: user, content: 'Erste Frage')
      thread
    end

    open_panel
    visit organisation_project_ticket_path(organisation, project, taken)

    # 1. Arriving on a ticket page: the offer stands, and NOTHING has been
    #    written. That second half is the actual rule of this bullet.
    eventually('the panel found the page object') { offering?(taken) }
    expect(offer[:class]).not_to include('hidden')
    expect(offer_label.text).to include("##{taken.number} Anmeldung schlaegt fehl")
    expect(offer_lead_set[:class].to_s).not_to include('hidden')
    expect(offer_lead_add[:class]).to include('hidden')
    # ⚠️ Behind a barrier, and it is not decoration: a probe that made
    #    offerPageContext write by itself stayed GREEN here until this line
    #    existed, because the requestSubmit it fires had not landed yet.
    await_round_trip
    expect(reference_ids_of(chat)).to eq([])
    # The take button is DESCRIBED by the sentence that is showing plus the
    # title. Its own text is only "Uebernehmen"; without the description a
    # screen reader gets no object and no verb.
    expect(offer_take['aria-describedby']).to eq('assistant_offer_set assistant_offer_label')

    # 2. Taking it goes down the SAME write as the button in the ticket header:
    #    the reference lands, and NOTHING else does. Since E3 (Bezugs-Sammlung
    #    §2.2) that write no longer carries the ticket's project into the scope
    #    chip -- an offer the user accepted with one click must not silently
    #    re-point where the assistant searches.
    offer_take.click
    eventually('the reference reached the database') do
      reference_ids_of(chat) == [taken.id]
    end
    expect(ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_project_id }).to be_nil
    expect(offer[:class]).to include('hidden')

    # 3. A different ticket with a reference already standing is a SWITCH, and it
    #    says so. Same strip, other sentence -- both are in the markup, so the
    #    accessible text is never patched in by JavaScript, only the id the
    #    button points at.
    #
    #    A TURBO visit, deliberately, and not Capybara's `visit`: that one is a
    #    browser load, which throws the JS context away and repeats the cold path
    #    of step 1. This is what a link click does -- the node is transplanted and
    #    the transcript comes along untouched, so the standing reference is really
    #    read off a chip that survived the navigation. It is also the ANCHOR for
    #    steps 5 and 7: it shows that a Turbo visit onto a ticket page produces an
    #    offer, so a later "no offer" there means something.
    turbo_visit(organisation_project_ticket_path(organisation, project, refused))
    eventually('the offer moved to the second ticket') { offering?(refused) }
    expect(offer_lead_add[:class].to_s).not_to include('hidden')
    expect(offer_lead_set[:class]).to include('hidden')
    expect(offer_take['aria-describedby']).to eq('assistant_offer_add assistant_offer_label')

    # 4. Refused by hand. And the focus comes back to the composer rather than
    #    being dropped on the body: hiding the element that HOLDS the focus
    #    strands anyone navigating by keyboard, which is the lesson this file
    #    already learned twice (open/restoreFocus). The take button escapes it
    #    only by accident, because adopting opens the panel and focuses there.
    offer.find('button[data-action="assistant-panel#dismissOffer"]', visible: :all).click
    expect(offer[:class]).to include('hidden')
    # ⚠️ The COMPOSER specifically, not merely "somewhere in the panel". This
    #    driver runs without stylesheets, so the hidden strip is not actually
    #    display:none and the x keeps the focus it had -- which is inside the
    #    panel too. Asserted loosely, this cell was green with the restoration
    #    deleted; measured, not guessed.
    eventually('the focus came back to the composer instead of staying on the x') do
      page.evaluate_script(
        "document.activeElement === document.querySelector('#assistant_panel [data-neo-chat-composer-target=\"field\"]')"
      )
    end

    # 5. The refusal is PER OBJECT: a third ticket still offers itself. Without
    #    this the next step would also be green if the strip had simply died.
    turbo_visit(organisation_project_ticket_path(organisation, project, control))
    eventually('a different ticket still offers itself') { offering?(control) }

    # 5b. A page that names NO object withdraws the offer instead of leaving it
    #     standing over something it is not about. Nothing covered this: no step
    #     ever navigated off a ticket, so deleting that guard left the strip
    #     showing the ticket before and every assertion green.
    turbo_visit(organisation_root_path(organisation_id: organisation.id))
    eventually('the offer withdrew on a page that names nothing') do
      offered_context.nil? && offer[:class].include?('hidden')
    end

    # 6. And it survives navigation, which is what the help text promises ("bis
    #    du die Seite neu laedst"). Two Turbo visits later, same page as step 4,
    #    same machinery as step 5 -- the only difference is the refusal.
    turbo_visit(organisation_project_ticket_path(organisation, project, refused))
    await_page_context(refused)
    expect(offered_context).to be_nil
    expect(offer[:class]).to include('hidden')

    # A new draft offers the page too, without creating a saved conversation.
    find('#assistant_panel a[title="Neuer Chat"]').click
    eventually('the transcript was exchanged for the empty state') do
      page.has_no_css?('#assistant_panel #assistant-panel-chat', visible: :all)
    end
    turbo_visit(organisation_project_ticket_path(organisation, project, control))
    await_page_context(control)
    eventually('the new draft offers the page object') { offering?(control) }
  end

  # The hook the document listener exists for, and the one every other example
  # here misses: the ticket detail lives in #ticket_display_frame, so moving from
  # one task to the next in the LIST exchanges a frame and never transplants the
  # panel. connect() does not run, and without the document listener the offer
  # would keep naming the ticket before.
  #
  # ⚠️ The row CLICK is not driven, and that is a limit of this driver rather
  # than a shortcut. layout_toggle sizes the grid in JavaScript
  # (layout_toggle_controller.js:324) and the driver runs with stylesheets off,
  # so with the panel open the list collapses to nothing the moment a task is
  # selected and Selenium refuses to click what it cannot see. What IS driven is
  # the exchange itself, byte for byte what ticket_row_controller.js:93 does with
  # the frame -- a real fetch, a real render, a real turbo:frame-load. The click
  # and the layout are not what this example is about.
  it 'follows a frame exchange in the page, where nothing is ever navigated' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht') }
    first, second = ActsAsTenant.with_tenant(organisation) do
      [create(:ticket, project: project, organisation: organisation, creator: user, title: 'Anmeldung schlaegt fehl'),
       create(:ticket, project: project, organisation: organisation, creator: user, title: 'Export bricht ab')]
    end
    # Bound, not looked up later: the sibling example names its row with
    # Chat.find, and reading Chat.where(user:).pick instead takes an UNORDERED
    # relation -- the day a second thread exists in this example the assertion
    # can answer nil from a row nobody ever wrote to, and go green for it.
    thread = ActsAsTenant.with_tenant(organisation) do
      created = create(:chat, :org_thread, organisation: organisation, user: user)
      created.chatposts.first.update!(user: user, content: 'Erste Frage')
      created
    end

    open_panel
    visit organisation_project_tickets_path(organisation, project)
    # Nothing selected yet, so the list names no object and the strip is quiet.
    # Behind a barrier: without one this is green from first paint, because
    # data-context-id has never been written in this example at all.
    eventually('the panel is up and has had its say about this page') do
      page.has_css?('#assistant_panel #assistant-panel-chat', visible: :all, wait: 0)
    end
    expect(offered_context).to be_nil

    show_in_ticket_frame(organisation_project_ticket_path(organisation, project, first))
    eventually('the frame brought the first task, and the offer found it') { offering?(first) }

    show_in_ticket_frame(organisation_project_ticket_path(organisation, project, second))
    eventually('the offer followed the exchange, with no navigation at all') { offering?(second) }
    expect(offer_label.text).to include("##{second.number} Export bricht ab")

    # And the page can drop its object without making a sound: turbo_cache
    # empties this frame with innerHTML in two places (turbo_cache_controller.js
    # 65 and 108), which fires no turbo:frame-load, so nothing tells the panel.
    # Taking the offer then has to refuse rather than write the ticket the strip
    # still remembers -- which is why takeOffer asks the page again instead of
    # trusting its own dataset.
    # And the page can drop its object without making a sound: turbo_cache empties
    # this frame with innerHTML in two places (the kanban slide-over did the same
    # on close, until the board got the lane). None of that fires an event, so no frame-load listener can
    # ever hear it -- the strip kept standing over a page that named nothing, and
    # its button was then a click that did nothing and said nothing. The page
    # observer is what closes this, and this is the only cell that drives it.
    #
    # ⚠️ NOT asserted by clicking. takeOffer's re-read refuses a stale strip, but
    # it refuses an EMPTY one the same way whether the guard is there or not, so
    # a click proves nothing here. The withdrawal does.
    page.execute_script("document.getElementById('ticket_display_frame').innerHTML = ''")
    eventually('the offer withdrew when the page stopped naming an object') do
      offered_context.nil? && offer[:class].include?('hidden')
    end

    # ...and nothing was written on the way. Behind a barrier: "nothing was
    # written" is green while a write is still in flight -- measured, a probe that
    # put the old behaviour back stayed green until this existed.
    await_round_trip
    expect(reference_ids_of(thread)).to eq([])
  end

  # The search skips the panel's OWN subtree, and until now nothing said so: the
  # marker is rendered by exactly one partial, which no example ever puts inside
  # #assistant_panel, so the line could be deleted with the whole suite green.
  #
  # The rule is not hypothetical. An answer may perfectly well quote a ticket, and
  # the artefact lane renders app content inside this node. A citation that became
  # an offer would let the assistant re-point the thread at whatever it had just
  # mentioned -- the panel talking itself into a new subject.
  #
  # Driven on a page that names NOTHING, deliberately: the panel sits after <main>
  # in the document, so on a ticket page the page's own marker comes first and the
  # exclusion would never be reached. With no marker on the page, the panel's is
  # the only one there is, and skipping it is the whole difference.
  it 'never offers what the panel itself is showing' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht') }
    quoted = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Zitiert in einer Antwort')
    end
    ActsAsTenant.with_tenant(organisation) do
      created = create(:chat, :org_thread, organisation: organisation, user: user)
      created.chatposts.first.update!(user: user, content: 'Erste Frage')
    end

    open_panel
    visit organisation_root_path(organisation_id: organisation.id)
    eventually('the panel is up and has had its say about this page') do
      page.has_css?('#assistant_panel #assistant-panel-chat', visible: :all, wait: 0)
    end
    expect(offered_context).to be_nil

    # A marker inside the panel, exactly as an answer quoting a ticket would leave
    # one, plus a change in <main> so the panel asks the question again.
    page.execute_script(<<~JS)
      const quote = document.createElement('div')
      quote.setAttribute('data-assistant-context', '#{quoted.id}')
      quote.setAttribute('data-assistant-context-type', 'Ticket')
      quote.setAttribute('data-assistant-context-label', '#1 Zitiert in einer Antwort')
      document.getElementById('assistant_panel_body').prepend(quote)
      document.querySelector('.mobile-app-screen > main, body > main').appendChild(document.createElement('span'))
    JS

    await_round_trip
    expect(offered_context).to be_nil
    expect(offer[:class]).to include('hidden')
  end

  # The two states around a reference that is ALREADY set, which the long arc
  # above cannot carry: it needs a standing reference for its later steps, and
  # both of these take one away.
  #
  # Neither was covered. Every step of the arc uses a ticket OTHER than the one
  # the thread points at, so the comparison against the chip could be deleted
  # outright and the suite stayed green -- and the flag that keeps a take from
  # being re-offered while it is in flight was cleared ONLY by a later run that
  # saw the chip standing on this very object. Remove the chip and the flag was
  # stranded: that ticket went silent for the life of the tab, with nothing on
  # screen to explain it and no way back short of a reload.
  it 'stays quiet on the ticket it already points at, and speaks again once that is undone' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht') }
    ticket = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Anmeldung schlaegt fehl')
    end
    thread = ActsAsTenant.with_tenant(organisation) do
      created = create(:chat, :org_thread, organisation: organisation, user: user)
      created.chatposts.first.update!(user: user, content: 'Erste Frage')
      created
    end

    open_panel
    visit organisation_project_ticket_path(organisation, project, ticket)
    eventually('the panel found the page object') { offering?(ticket) }

    offer_take.click
    eventually('the reference reached the database') do
      reference_ids_of(thread) == [ticket.id]
    end

    # 1. Back on the very ticket the thread points at: nothing to take, so
    #    nothing is offered.
    turbo_visit(organisation_project_ticket_path(organisation, project, ticket))
    await_page_context(ticket)
    await_round_trip
    expect(offered_context).to be_nil
    expect(offer[:class]).to include('hidden')

    # 2. Reference removed with the chip's own x, and the same ticket offers
    #    itself again.
    find('#assistant_panel [data-reference-keys] button[type="submit"]').click
    eventually('the reference was cleared') do
      page.has_no_css?('#assistant_panel [data-reference-keys]', visible: :all, wait: 0)
    end
    turbo_visit(organisation_project_ticket_path(organisation, project, ticket))
    eventually('the ticket offers itself again once the reference is gone') do
      offering?(ticket)
    end
    expect(offer_lead_set[:class].to_s).not_to include('hidden')
  end

  # The cookie has TWO writers: this controller composes the string, and
  # AssistantPanelState parses it. Nothing in Ruby can catch them drifting apart
  # -- a changed separator, a float width, a swapped order -- so the browser has
  # to hand its own cookie to the real parser and see what comes back.
  #
  # The example above only ever exercises the DEFAULT width, so a JS-side format
  # change to the width alone would slip past it.
  it 'writes a cookie the server parser reads back, width and mode alike' do
    open_panel
    resize_handle = find('#assistant_panel [role="separator"]', visible: :all)
    4.times { resize_handle.send_keys(:arrow_right) }
    find("#assistant_panel button[data-action='assistant-panel#expandToFull']").click

    raw = nil
    eventually('the cookie carries the mode') do
      raw = page.driver.browser.manage.all_cookies.find { |c| c[:name] == AssistantPanelState::COOKIE_NAME }&.dig(:value)
      raw.to_s.include?(AssistantPanelState::MODE_FULL)
    end

    state = AssistantPanelState.from_cookie(CGI.unescape(raw))

    expect(state).to be_open
    expect(state).to be_full
    # Four arrow presses at RESIZE_STEP each, which the browser wrote and the
    # parser has to give back unchanged rather than falling to the default.
    expect(state.width).to eq(AssistantPanelState::DEFAULT_WIDTH + (4 * 24))
  end

  it 'remembers open state and width in the cookie, so a full reload paints them server-side' do
    open_panel

    visit organisation_root_path(organisation_id: organisation.id)

    # A full load: the living node died and came back from the SERVER, already
    # open and already shifted -- no jump once JavaScript wakes up.
    expect(panel[:class]).not_to include('hidden')
    expect(main_offset).to eq("#{AssistantPanelState::SIDEBAR_WIDTH + AssistantPanelState::DEFAULT_WIDTH}px")
  end
  # --- earlier conversations (S3c T1, plan §7.6) ------------------------------
  #
  # Before this the panel served the newest own thread and nothing linked to any
  # other one, so an older conversation was reachable only for somebody who had
  # kept its address. What a browser has to settle here is that the list is a
  # COMPANION move, not a navigation: picking an old thread must exchange what
  # the panel shows while the page underneath stands still.
  describe 'the list of earlier conversations' do
    def thread(content, created_at:)
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, :org_thread, organisation: organisation, user: user, created_at: created_at)
        chat.chatposts.first.update!(user: user, content: content)
        chat
      end
    end

    let!(:older) { thread('Aeltere Frage', created_at: 2.days.ago) }
    let!(:newer) { thread('Neuere Frage', created_at: 1.hour.ago) }

    def open_history
      open_panel
      # The transcript has to be there before the button can read the open
      # thread off it -- that is the whole reason the button is not a link.
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{newer.id}']", visible: :all)
      find("#assistant_panel button[data-action='assistant-panel#showHistory']").click
    end

    it 'opens an older thread WITHOUT moving the page' do
      before_url = page.current_url
      open_history

      expect(page).to have_text('Aeltere Frage')
      find("#assistant_panel a[data-chat-id='#{older.id}']").click

      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)
      expect(page.current_url).to eq(before_url)
    end

    # The button carries the open thread as ?current=, which is the only way the
    # list can know it: the header is a permanent node the server can never
    # re-render.
    it 'marks the thread that was open when the list was called' do
      open_history

      expect(page).to have_css(
        "#assistant_panel a[data-chat-id='#{newer.id}'][data-assistant-history-current='true']", visible: :all
      )
      expect(page).to have_css(
        "#assistant_panel a[data-chat-id='#{older.id}'][data-assistant-history-current='false']", visible: :all
      )
    end

    # The button has no open/closed state, so pressing it again is the natural
    # thing to try. It must not cost the way back: the second press cannot see
    # the chat frame any more (the list replaced it), would rebuild the address
    # without ?current=, and the arrow would land on the NEWEST thread instead
    # of the one the list was opened from.
    it 'survives a second press on the button without losing the way back' do
      open_history
      find("#assistant_panel a[data-chat-id='#{older.id}']").click
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)

      find("#assistant_panel button[data-action='assistant-panel#showHistory']").click
      expect(page).to have_css(
        "#assistant_panel a[data-chat-id='#{older.id}'][data-assistant-history-current='true']", visible: :all
      )

      find("#assistant_panel button[data-action='assistant-panel#showHistory']").click
      expect(page).to have_css(
        "#assistant_panel a[data-chat-id='#{older.id}'][data-assistant-history-current='true']", visible: :all
      )

      find("#assistant_panel a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']").click

      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)
    end

    # Regression, found in production (26.08.2026): after a trip to the full view
    # the clock did nothing at all any more.
    #
    # The bolt against the second press asked `this.element`, i.e. the WHOLE
    # panel node -- and since T2 the history lane renders the same component with
    # the same marker inside exactly that node. One visit to the full view loads
    # the lane, the marker then stays in the DOM (the lane is only display:none),
    # and from then on the bolt bails out immediately on EVERY press.
    it 'still opens the list after a trip to the full view and back' do
      open_panel
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{newer.id}']", visible: :all)

      find("#assistant_panel button[data-action='assistant-panel#expandToFull']").click
      # The lane must really have loaded, otherwise the marker is not there at all
      # and the test would miss the defect.
      eventually('die Lane hat geladen') do
        page.evaluate_script(
          %{!!document.querySelector('#assistant_panel_history [data-assistant-history]')}
        )
      end
      find("#assistant_panel button[data-action='assistant-panel#collapseToPanel']").click

      find("#assistant_panel button[data-action='assistant-panel#showHistory']").click

      expect(page.find('#assistant_panel_body', visible: :all))
        .to have_text(I18n.t('views.organisations.assistant_panels.history.title'), wait: 5)
    end

    it 'comes back to the conversation it was called from' do
      open_history

      find("#assistant_panel a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']").click

      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{newer.id}']", visible: :all)
    end
  end
  # --- the full view (S3c T2, plan §4, L11) -----------------------------------
  #
  # The claim this ticket rests on, and the only reason the full view is a STATE
  # of the permanent node rather than a page of its own: going up and coming back
  # down must not touch the conversation. A page would have re-rendered it, and
  # with it thrown away the draft, the scroll position and a streaming answer.
  # Only a browser can settle that.
  describe 'the full view' do
    def expand_button   = find("#assistant_panel button[data-action='assistant-panel#expandToFull']")
    def collapse_button = find("#assistant_panel button[data-action='assistant-panel#collapseToPanel']")
    def panel_classes   = panel[:class]
    def history_lane    = page.find('#assistant_panel_history', visible: :all)
    def resize_handle   = page.find('#assistant_panel [role="separator"]', visible: :all)

    def type_draft(text)
      eventually('the composer arrived') { !composer_value.nil? }
      page.execute_script(
        %{const f = document.querySelector('#assistant_panel [data-neo-chat-composer-target="field"]');
          f.value = arguments[0]; f.dispatchEvent(new Event('input', { bubbles: true }))},
        text
      )
      expect_composer_value(text)
    end

    it 'keeps the typed draft across the way up AND back down' do
      open_panel
      type_draft('Halbfertige Frage')

      expand_button.click
      expect(panel_classes).to include('assistant-panel--full')
      expect_composer_value('Halbfertige Frage')

      collapse_button.click
      expect(panel_classes).not_to include('assistant-panel--full')
      expect_composer_value('Halbfertige Frage')
    end

    it 'brings the history lane along and takes it away again' do
      open_panel

      expand_button.click
      # Loaded lazily, so the src is the honest signal that it was fetched at all.
      eventually('the lane armed itself') { history_lane[:src].to_s.include?('lane=1') }

      collapse_button.click
      expect(panel_classes).not_to include('assistant-panel--full')
    end

    # Up there the width belongs to the layout (§7.7). A drag handle on an edge
    # pinned to the viewport would promise something it cannot deliver.
    it 'puts the resize handle away and stops shifting the page' do
      open_panel
      expect(main_offset).to be_present

      expand_button.click

      expect(resize_handle[:class]).to include('hidden')
      expect(main_offset).to be_blank
      expect(body_class).to include('assistant-panel-full')
    end

    # Found in a screenshot, not in a test: the overlay list's button survived
    # into the full view, where the lane already shows the same list. Clicking it
    # would have loaded the conversation list a SECOND time, into the chat frame,
    # so the panel would show it twice side by side.
    it 'puts the overlay list button away, the lane already shows that list' do
      open_panel
      history_button = find("#assistant_panel button[data-action='assistant-panel#showHistory']")
      expect(history_button[:class]).not_to include('hidden')

      expand_button.click

      expect(history_button[:class]).to include('hidden')
    end

    # The cookie carries the mode, so the SERVER paints the full view on a hard
    # reload instead of the page jumping once the controller connects.
    it 'survives a hard reload as the full view' do
      open_panel
      expand_button.click
      eventually('the mode reached the cookie') do
        page.driver.browser.manage.all_cookies.any? { |c| c[:name] == 'assistant_panel' && c[:value].include?('full') }
      end

      visit organisation_root_path(organisation_id: organisation.id)

      expect(panel_classes).to include('assistant-panel--full')
    end

    # The shareable address, end to end: the controller redirects with
    # ?assistant=full and the panel picks it up from the URL. Only a browser can
    # settle the second half, because a permanent node never sees what the server
    # rendered for it.
    it 'opens maximised when someone arrives through the shared address' do
      visit organisation_assistant_path(organisation_id: organisation.id)

      expect(panel[:class]).not_to include('hidden')
      expect(panel_classes).to include('assistant-panel--full')
      eventually('the lane armed itself') { history_lane[:src].to_s.include?('lane=1') }
    end

    # The morph refresh after every finished answer re-visits the SAME url. Without
    # the once-per-address marker that would keep re-opening the full view under
    # somebody who had just collapsed it.
    it 'does not re-open the full view after the user collapsed it on that address' do
      visit organisation_assistant_path(organisation_id: organisation.id)
      expect(panel_classes).to include('assistant-panel--full')

      collapse_button.click
      expect(panel_classes).not_to include('assistant-panel--full')

      # A REAL Turbo visit to the same address, which is what the morph refresh
      # after a finished answer does: the permanent node is transplanted and
      # connect() runs again with ?assistant=full still in the URL.
      #
      # Two things this test needed before it held anything. A synthetic
      # "connect" event does nothing (the first version dispatched one and stayed
      # green with the marker deleted), and the assertion has to WAIT for the
      # visit -- the panel node is present the whole time, so there is no natural
      # Capybara wait point and the second version measured before the visit had
      # landed. Hence the counter.
      page.execute_script('window.__assistantVisits = 0; ' \
                          'document.addEventListener("turbo:load", () => window.__assistantVisits++)')
      page.execute_script('window.Turbo.visit(window.location.href, { action: "replace" })')
      eventually('the turbo visit landed') { page.evaluate_script('window.__assistantVisits').to_i >= 1 }

      expect(panel_classes).not_to include('assistant-panel--full')
    end

    # Closing is a way out of the excursion, not a way to store it: a Cmd+J that
    # unexpectedly fills the screen is a bad way to start one.
    it 'comes back as the companion panel after closing' do
      open_panel
      expand_button.click
      expect(panel_classes).to include('assistant-panel--full')

      find('body').send_keys([:control, 'j'])
      expect(panel[:class]).to include('hidden')

      find('body').send_keys([:control, 'j'])
      expect(panel_classes).not_to include('assistant-panel--full')
    end
  end

  # S3c T3 (plan §4, §8.1): the third lane. Source chips that stand for content
  # WITHOUT a page of its own open it; everything with a page keeps opening the
  # real app, and the panel steps out of the way for that.
  describe 'the artefact lane' do
    def expand_button = find("#assistant_panel button[data-action='assistant-panel#expandToFull']")
    def panel_classes = panel[:class]
    def artefact_lane = page.find('#assistant_panel_artefact', visible: :all)
    def artefact_param = Rack::Utils.parse_query(URI.parse(page.current_url).query)['assistant_artefact']

    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

    let!(:permission) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_permission, user: user, project: project,
                                         can_view_own: true, can_view_all: true)
      end
    end

    let!(:booking) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, project: project, organisation: organisation, creator: user,
                              duration: 75, description: 'Gebuchte Recherche', occurred_on: 2.days.ago)
      end
    end

    let!(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation) } }

    # An answer with two kinds of source: one that HAS a panel (the time report)
    # and one that has a page of its own (the ticket). Both behaviours are in one
    # thread on purpose -- they are decided by the same click handler.
    let!(:thread_with_sources) do
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, :org_thread, organisation: organisation, user: user)
        chat.chatposts.first.update!(user: user, content: 'Wie viel habe ich gebucht?')
        create(:chatpost, chat: chat, organisation: organisation, user: user, role: 'assistant',
                          content: 'Insgesamt 1:15 Stunden.',
                          source_citations: [
                            Lalabase::Citations.time_report(project, {}).deep_stringify_keys,
                            Lalabase::Citations.ticket(ticket).deep_stringify_keys
                          ])
        chat
      end
    end

    def open_full_with_sources
      visit organisation_root_path(organisation_id: organisation.id,
                                   assistant_chat_id: thread_with_sources.id)
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{thread_with_sources.id}']", visible: :all)
      expand_button.click
      expect(panel_classes).to include('assistant-panel--full')
    end

    # The source list renders inside a collapsed <details> (deliberately quiet,
    # see the citation component). A hidden link is not clickable, so the chips
    # have to be unfolded exactly as a person would unfold them.
    def source_link(matching)
      page.find('#assistant_panel [data-testid="citation-list"] summary').click unless sources_open?
      page.find("#assistant_panel li a[href*='#{matching}']")
    end

    def sources_open?
      page.evaluate_script(%{!!document.querySelector('#assistant_panel [data-testid="citation-list"]')?.open})
    end

    it 'opens the report beside the conversation instead of navigating away' do
      open_full_with_sources
      page_before = page.current_path

      source_link('time-tracking').click

      expect(artefact_lane).to have_text('Gebuchte Recherche', wait: 5)
      expect(panel_classes).to include('assistant-panel--artefact')
      # The page underneath did not move, and neither did the conversation.
      expect(page.current_path).to eq(page_before)
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{thread_with_sources.id}']", visible: :all)
    end

    # §13-10: the open panel belongs in the address, so a reload keeps it and the
    # link can be handed on. Written with replaceState -- opening a panel is not
    # a page visit and must not push a history entry per source click.
    it 'writes the open panel into the address and comes back to it after a reload' do
      open_full_with_sources
      source_link('time-tracking').click
      expect(artefact_lane).to have_text('Gebuchte Recherche', wait: 5)

      expect(artefact_param).to include('kind=report')

      page.refresh
      expect(artefact_lane).to have_text('Gebuchte Recherche', wait: 5)
      expect(panel_classes).to include('assistant-panel--artefact')
    end

    it 'closes the lane again and takes the address with it' do
      open_full_with_sources
      source_link('time-tracking').click
      expect(artefact_lane).to have_text('Gebuchte Recherche', wait: 5)

      find("#assistant_panel button[data-action='assistant-panel#closeArtefact']").click

      expect(panel_classes).not_to include('assistant-panel--artefact')
      expect(artefact_param).to be_nil
    end

    # The defect T2 shipped with: in the full view the panel COVERS the page, so
    # a source that navigates loaded its page behind a full-screen panel and the
    # click looked like it did nothing. Now the panel steps down first.
    it 'steps down to the companion mode when a source with its own page is clicked' do
      open_full_with_sources

      source_link("/tickets/#{ticket.id}").click

      expect(page).to have_current_path(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id), wait: 5)
      expect(panel_classes).not_to include('assistant-panel--full')
    end
  end

  # Feinschliff P3: the transparency note folds away, and only a browser can say
  # whether it unfolds again. The disclosure itself is native <details>, so what
  # these examples are really about is what the controller adds on top: Escape and
  # a click beside it, both of which have to survive a Turbo transplant.
  describe 'the transparency note' do
    def summary    = find('#assistant_panel details[data-controller="neo-ai-disclosure"] summary', visible: :all)

    def open_note? = page.has_css?('#assistant_panel details[data-controller="neo-ai-disclosure"][open]',
                                   visible: :all, wait: 2)

    # ⚠️ Waiting for the ELEMENT is not enough. The disclosure is native, so the
    # markup works the moment the frame lands, while the Stimulus controller
    # connects a tick later — and everything below is about what the controller
    # adds. Clicking in that window opened the note with no listeners attached and
    # made this group flake at roughly one run in five.
    before do
      open_panel
      expect(page).to have_css('#assistant_panel details[data-controller="neo-ai-disclosure"]', visible: :all)
      wait_for_stimulus('#assistant_panel details[data-controller="neo-ai-disclosure"]', 'neo-ai-disclosure')
    end

    it 'unfolds on the summary and folds back on it' do
      expect(open_note?).to be(false)

      summary.click
      expect(open_note?).to be(true)

      summary.click
      expect(open_note?).to be(false)
    end

    it 'folds back on Escape, and takes ONLY the note with it' do
      summary.click
      expect(open_note?).to be(true)

      # From INSIDE the panel, where the focus actually is after the click. Sent to
      # `body` the key never travels through the panel node, and the panel's own
      # Escape handler is not even reached — the first version of this example
      # asserted nothing.
      summary.send_keys(:escape)

      expect(open_note?).to be(false)
      # The panel listens for Escape as well. Without the innermost open thing
      # claiming the key, one press would close the whole assistant behind the note
      # somebody just unfolded.
      expect(panel[:class]).not_to include('hidden')
    end

    it 'folds back on a click beside it' do
      summary.click
      expect(open_note?).to be(true)

      find('#assistant_panel h2').click

      expect(open_note?).to be(false)
    end

    # Review of #625: the Escape listener sits on the document in the CAPTURE phase
    # and stops propagation, so without a focus guard an open note swallows the key
    # from every other layer in the app — the search overlay, a dropdown, a modal,
    # all of which listen further down. The note is not even visible in that
    # situation.
    it 'leaves Escape alone when the focus is not inside the note' do
      summary.click
      expect(open_note?).to be(true)

      # Focus in the composer, which is where it is while somebody types — the note
      # stands open beneath. Escape now belongs to the panel, as it did before this
      # PR existed.
      find('#assistant_panel [data-neo-chat-composer-target="field"]').send_keys(:escape)

      expect(panel[:class]).to include('hidden')
    end

    # A <details> takes its content out of the layout when it closes, so a keyboard
    # user who tabbed to the privacy link inside would lose the focus to <body>.
    # The sibling control (details_autoclose_controller) hands it back to the
    # summary; this one has to do the same. The link only exists once the operator
    # has stored a privacy address (LegalIdentity).
    it 'hands the focus back to the summary when it closes from inside',
       legal_identity: { privacy_page_url: 'https://public.example/privacy' } do
      summary.click
      expect(open_note?).to be(true)

      find('#assistant_panel details[data-controller="neo-ai-disclosure"] a', visible: :all)
        .send_keys(:escape)

      expect(open_note?).to be(false)
      expect(page.evaluate_script('document.activeElement.tagName')).to eq('SUMMARY')
    end

    # The panel is data-turbo-permanent: a navigation transplants this node,
    # disconnect() and connect() fire on the SAME instance, and <details open>
    # survives. If connect() does not pick the listeners back up, the note stays
    # open with Escape and click-beside silently dead.
    it 'keeps Escape working after a Turbo navigation with the note standing open' do
      summary.click
      expect(open_note?).to be(true)

      page.execute_script("Turbo.visit('#{organisation_appearance_path(organisation)}')")
      expect(page).to have_current_path(organisation_appearance_path(organisation), ignore_query: true)
      expect(open_note?).to be(true)

      summary.send_keys(:escape)

      expect(open_note?).to be(false)
      expect(panel[:class]).not_to include('hidden')
    end
  end
  # ---------------------------------------------------------------------------
  # The gear: the assistant's settings, and the persona picked there
  # ---------------------------------------------------------------------------
  #
  # Browser-only claims, exactly like the history list above: the button reads
  # the open thread off the transcript, the picker auto-submits, and the way back
  # has to return to the conversation it was opened from. None of that is visible
  # to a request spec, which never runs assistant_panel_controller.js.
  describe 'the settings behind the gear' do
    let!(:persona) do
      create(:prompt_persona, key: 'deep_dive',
                              labels: { 'de' => 'Tiefe Analyse', 'en' => 'Deep dive' })
    end

    # created_at is explicit and it MATTERS: the panel default is own_threads.first,
    # ordered created_at DESC, i.e. the NEWEST thread. A test that navigates to a
    # thread which happens to be the newest cannot tell the way back from the
    # fallback -- measured: with ?current= dropped from the controller, an earlier
    # version of these examples stayed green for exactly that reason.
    def thread(content, created_at:)
      ActsAsTenant.with_tenant(organisation) do
        chat = create(:chat, :org_thread, organisation: organisation, user: user, created_at: created_at)
        chat.chatposts.first.update!(user: user, content: content)
        chat
      end
    end

    # The newest, so it is what the panel opens by default AND what the fallback
    # would land on.
    let!(:open_thread) { thread('Laufende Frage', created_at: 1.hour.ago) }

    def open_settings
      open_panel
      # The transcript first, for the reason the history helper gives: the button
      # reads the open thread off it, and that is why it is not a link.
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{open_thread.id}']", visible: :all)
      find("#assistant_panel button[data-action='assistant-panel#showSettings']").click
      expect(page).to have_css('#assistant_panel [data-assistant-settings]', visible: :all)
    end

    it 'opens the settings in the panel WITHOUT moving the page' do
      before_url = page.current_url
      open_settings

      expect(page).to have_css('#assistant_panel select#assistant_persona_select', visible: :all)
      expect(page.current_url).to eq(before_url)
    end

    # The point of the whole feature: picking stores the choice.
    it 'stores the picked persona and keeps it selected' do
      open_settings

      find('#assistant_panel select#assistant_persona_select', visible: :all).select('Tiefe Analyse')

      expect(page).to have_css(
        "#assistant_panel select#assistant_persona_select option[value='#{persona.id}'][selected]", visible: :all
      )
      stored = ActsAsTenant.with_tenant(organisation) do
        ChatStylePreference.find_by(user: user, organisation: organisation)&.prompt_persona_id
      end
      expect(stored).to eq(persona.id)
    end

    # The way back is what ?current= is for. Without it the arrow lands on the
    # panel default, which is the NEWEST thread, and switches the conversation
    # under somebody who only opened the settings.
    it 'returns to the conversation it was opened from' do
      older = thread('Aeltere Frage', created_at: 2.days.ago)
      open_panel
      find("#assistant_panel button[data-action='assistant-panel#showHistory']").click
      find("#assistant_panel a[data-chat-id='#{older.id}']").click
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)

      find("#assistant_panel button[data-action='assistant-panel#showSettings']").click
      expect(page).to have_css('#assistant_panel [data-assistant-settings]', visible: :all)
      find('#assistant_panel [data-assistant-settings] a').click

      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)
    end

    # The gear has no open/closed state, so pressing it twice is the natural
    # thing to try. The second press cannot see the chat frame any more (the
    # settings replaced it) and would rebuild the address without ?current=.
    it 'survives a second press on the gear without losing the way back' do
      older = thread('Aeltere Frage', created_at: 2.days.ago)
      open_panel
      find("#assistant_panel button[data-action='assistant-panel#showHistory']").click
      find("#assistant_panel a[data-chat-id='#{older.id}']").click
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)

      find("#assistant_panel button[data-action='assistant-panel#showSettings']").click
      expect(page).to have_css('#assistant_panel [data-assistant-settings]', visible: :all)
      find("#assistant_panel button[data-action='assistant-panel#showSettings']").click

      find('#assistant_panel [data-assistant-settings] a').click
      expect(page).to have_css("#assistant-panel-chat[data-chat-id='#{older.id}']", visible: :all)
    end
  end
end

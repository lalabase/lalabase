# frozen_string_literal: true

require 'rails_helper'

# T-9b (Bezugs-Sammlung plan §12, §8.3): the loop the LIMIT creates, and the one
# thing about it that only a browser can settle.
#
# A refusal has no event of its own. `settleAfterScopeWrite` recognises one by the
# chip row coming back unchanged, and `offerPageContext` then offers the very same
# object again, because the collection still does not contain it. With a limit of
# one that was rare; with ten it is routine: click, 422 "at most ten", offer,
# click, 422. So a refused key goes into `dismissedContexts` -- and the two
# conditions in that method are what keep a successful DUPLICATE (unchanged too,
# but a member afterwards) out of it.
#
# ⚠️ Its OWN file, and that is a finding rather than a preference. Inside
# assistant_panel_spec this example made a much later one fail -- the transparency
# note's Escape, which the file's own comment already records as having flaked
# once at about one run in five. Measured: the panel file alone was green WITH
# this example, and green WITHOUT it when both system files ran together; only
# "both files plus this example" was red, three times out of three, and the
# screenshot showed the panel closed rather than the note. Both examples pass in
# isolation, so the interaction is cumulative, not a pair. This example is by some
# way the heaviest in that file (thirteen tickets, a collection at the limit, a
# refusal and two navigations), and it also has the least in common with it: the
# rest of that file is about the panel, this is about the collection's limit.
RSpec.describe 'Assistant reference limit', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

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

  def panel   = page.find('[data-assistant-panel-target="panel"]', visible: :all)
  def offer   = page.find('[data-assistant-panel-target="offer"]', visible: :all)
  def offer?  = page.has_css?('[data-assistant-panel-target="offer"]', visible: :all, wait: 0)
  # "No offer" has two shapes since the strip moved into the chat frame: rendered
  # and carrying `hidden`, or not rendered at all because there is no transcript
  # for it to sit above.
  def no_offer? = !offer? || offer[:class].include?('hidden')
  def offer_lead_add = page.find('[data-assistant-panel-target="offerAdd"]', visible: :all)
  def offer_take     = page.find('[data-assistant-panel-target="offerTake"]', visible: :all)
  def offering?(record) = offer['data-context-id'] == "#{record.class.name}:#{record.id}"

  def open_panel
    find('#assistant-panel-trigger').click
    expect(panel[:class]).not_to include('hidden')
  end

  # A real Turbo visit, i.e. what a link click does: the permanent node is
  # transplanted and the loaded transcript comes along.
  def turbo_visit(path) = page.execute_script("Turbo.visit('#{path}')")

  # Waits for the PAGE, not for the strip. Without it "the offer stays away" is
  # already true before the navigation lands.
  def await_page_context(ticket)
    eventually("the page for ##{ticket.number} arrived and named its object") do
      page.has_css?("[data-assistant-context='#{ticket.id}']", visible: :all, wait: 0)
    end
  end

  # A server round trip AFTER the thing under test, as a barrier: without one,
  # "nothing came back" is green because nothing has ARRIVED yet.
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

  def eventually(description)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until yield
    end
  rescue Timeout::Error
    raise "never became true: #{description}"
  end

  def reference_ids_of(chat)
    ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_references }.map { |entry| entry['id'] }
  end

  # ⚠️ The control ticket is not decoration. "The strip stays away" is green for a
  # strip that simply died, and this feature has been bitten by exactly that shape
  # before.
  it 'stops offering a context the collection refused, and keeps offering others' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht') }
    full, refused, control = ActsAsTenant.with_tenant(organisation) do
      [Array.new(Assistant::ReferenceRegistry::MAX_REFERENCES) do |i|
         create(:ticket, project: project, organisation: organisation, creator: user, title: "Bezug #{i}")
       end,
       create(:ticket, project: project, organisation: organisation, creator: user, title: 'Der elfte'),
       create(:ticket, project: project, organisation: organisation, creator: user, title: 'Ein anderer')]
    end
    chat = ActsAsTenant.with_tenant(organisation) do
      thread = create(:chat, :org_thread, organisation: organisation, user: user)
      thread.chatposts.first.update!(user: user, content: 'Erste Frage')
      thread.update!(scope_references: full.map do |ticket|
        Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)
      end)
      thread
    end

    open_panel
    visit organisation_project_ticket_path(organisation, project, refused)

    # The collection is full, so the strip offers to ADD rather than to set.
    eventually('the panel found the page object') { offering?(refused) }
    expect(offer_lead_add[:class].to_s).not_to include('hidden')

    offer_take.click

    # Refused, and it SAYS so -- the row comes back identical, which is the only
    # shape a refusal has on this path.
    eventually('the refusal reached the screen') do
      page.has_text?(I18n.t('flash.assistant_chats.reference_limit',
                            count: Assistant::ReferenceRegistry::MAX_REFERENCES), wait: 0)
    end
    expect(reference_ids_of(chat)).to match_array(full.map(&:id))

    # And it does NOT come back for this ticket. The barrier matters: without it
    # "no offer" is true simply because nothing has happened yet.
    await_round_trip
    expect(no_offer?).to be(true)

    # The anchor: a different ticket still offers itself, so the strip is alive
    # and the silence above is about THIS object.
    turbo_visit(organisation_project_ticket_path(organisation, project, control))
    await_page_context(control)
    eventually('a different ticket still offers itself') { offering?(control) }
  end
end

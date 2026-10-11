# frozen_string_literal: true

require 'rails_helper'

# S3a T4 — the one thing about the companion panel that only real CSS can settle:
# does a long conversation stay INSIDE the panel?
#
# It has its own file because it needs a different driver. The default system
# driver switches stylesheets off (see the note in assistant_panel_spec), which
# is right for asserting classes and wrong for asserting layout — and it is
# exactly why a broken selector went unnoticed once already: the panel rules were
# written against the chat frame's id, the frame later got an id of its own, and
# all three rules silently stopped matching. Nothing was red. The transcript ran
# out of the bottom of the panel and took the composer with it.
#
# So this spec asks the browser the question the user would ask: can I still
# reach the field I am supposed to type into?
RSpec.describe 'Assistant panel layout (with stylesheets)', type: :system do
  # CSS- and image-faithful driver (spec/support/capybara.rb). Set here rather
  # than through the :inbox_e2e tag, which means something else.
  before do
    driven_by :selenium_chrome_headless_full
    # Capybara reuses this driver after mobile specs that resize its window.
    # These desktop geometry expectations use the driver's 1440px default.
    page.driver.browser.manage.window.resize_to(1440, 900)
  end

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

  # Long enough that the transcript cannot possibly fit the panel's height.
  let!(:long_thread) do
    ActsAsTenant.with_tenant(organisation) do
      chat = create(:chat, :org_thread, organisation: organisation, user: user)
      chat.chatposts.first.update!(user: user, content: 'Erste Frage')
      40.times { |i| create(:chatpost, chat: chat, organisation: organisation, user: user, content: "Nachricht #{i}") }
      chat
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    visit organisation_root_path(organisation_id: organisation.id)
    find('#assistant-panel-trigger').click
    expect(page).to have_css('#assistant_panel_body [data-neo-chat-composer-target="field"]', visible: :all)
  end

  def box(selector)
    page.evaluate_script("JSON.parse(JSON.stringify(document.querySelector('#{selector}').getBoundingClientRect()))")
  end

  # <main> carries `transition-all duration-500`, so measuring right after the
  # click catches the geometry mid-flight (a first version of this spec read
  # 542px on its way from 256 to 636 and failed on a layout that was correct).
  # Poll like Capybara does instead of asserting on one snapshot.
  def eventually(description)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until yield
    end
  rescue Timeout::Error
    raise "never became true: #{description}"
  end

  it 'scrolls the transcript inside its own container instead of growing the panel' do
    log = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('#assistant_panel [role="log"]')
        return { scrollHeight: el.scrollHeight, clientHeight: el.clientHeight,
                 overflowY: getComputedStyle(el).overflowY }
      })()
    JS

    expect(log['overflowY']).to eq('auto')
    # The proof that it is a scroll container and not just a tall box.
    expect(log['scrollHeight']).to be > log['clientHeight']
  end

  # Whether the transcript's end is on screen: the same 8px tolerance the follow
  # uses (chat_scroll_controller DRIFT_PX), because browsers round scrollTop.
  def transcript_at_end?
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('#assistant_panel [role="log"]')
        return el.scrollHeight - el.scrollTop - el.clientHeight <= 8
      })()
    JS
  end

  # Opening the panel is opening a conversation, and a conversation is read from
  # its END: what was said last is what you came back for. Without this the
  # transcript opened at the first message and the reader dragged the scrollbar
  # down through forty of them, every time.
  it 'opens at the end of the transcript' do
    eventually('the transcript was scrolled to its end') { transcript_at_end? }
  end

  # The panel is display:none while closed, so the position it had is not worth
  # keeping anyway; and the reader who reopens it wants the latest, not where
  # they happened to leave off.
  it 'shows the end again after closing and reopening' do
    eventually('the transcript was scrolled to its end') { transcript_at_end? }
    page.execute_script("document.querySelector('#assistant_panel [role=\"log\"]').scrollTop = 0")
    expect(transcript_at_end?).to be(false)

    find('#assistant_panel [data-action="assistant-panel#close"]').click
    find('#assistant-panel-trigger').click

    eventually('the transcript was scrolled to its end again') { transcript_at_end? }
  end

  # The arrangement of the writing zone, measured rather than read off the markup
  # (27.08.2026). The component spec pins the ORDER in the HTML; only a browser
  # with stylesheets on can say the rows actually landed above and below the
  # field -- both rows are flex parents of chips that render as display:contents,
  # which is precisely the kind of markup where source order and painted position
  # can part company.
  it 'shows what it looks AT above the field, and how it answers below' do
    context_row = box('#assistant_panel .chat-context-row')
    field = box('#assistant_panel [data-neo-chat-composer-target="field"]')
    style_row = box('#assistant_panel .chat-style-row')

    expect(context_row['top']).to be <= field['top']
    expect(style_row['top']).to be >= field['bottom']
  end

  # The reason this feature was asked for: the composer sits BELOW the log, so a
  # streaming answer grows out of the bottom of the panel and the reader had to
  # drag the scrollbar back down by hand, over and over, while the text arrived.
  #
  # What is simulated here is the MUTATION, not the broadcast that normally
  # causes it: a growing block appended to the log is byte for byte the DOM change
  # a streamed answer makes (Chatpost#broadcast_updated replaces the post once per
  # token). How the mutation arrives has its own specs; what this one asks is
  # whether the transcript follows it.
  #
  it 'follows a growing answer instead of leaving the reader behind' do
    field = find('#assistant_panel [data-neo-chat-composer-target="field"]')
    field.set('Eine Frage an den Assistenten')
    field.send_keys(:enter)

    # The jump has happened once this is on screen, and with it the disarm -- so
    # what follows is measured against the FOLLOW and not against the jump.
    eventually('the question reached the transcript') do
      page.has_text?('Eine Frage an den Assistenten', wait: 0)
    end

    page.execute_script(<<~JS)
      const log = document.querySelector('#assistant_panel [role="log"]')
      const grown = document.createElement('div')
      grown.style.height = '2000px'
      grown.textContent = 'Eine sehr lange Antwort'
      log.appendChild(grown)
    JS

    eventually('the transcript followed the answer to its end') do
      page.evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector('#assistant_panel [role="log"]')
          return el.scrollHeight - el.scrollTop - el.clientHeight <= 8
        })()
      JS
    end
  end

  # The other half of the same rule, and the one that makes the follow bearable:
  # a reader who scrolled UP to re-read something is not dragged back down by the
  # next token. Without it "follows the answer" is just "steals the scrollbar".
  it 'stops following once the reader scrolls up' do
    field = find('#assistant_panel [data-neo-chat-composer-target="field"]')
    field.set('Noch eine Frage')
    field.send_keys(:enter)
    eventually('the question reached the transcript') { page.has_text?('Noch eine Frage', wait: 0) }

    # Straight to the top: unambiguously the reader's own move, and far enough
    # that no rounding can be mistaken for it.
    page.execute_script("document.querySelector('#assistant_panel [role=\"log\"]').scrollTop = 0")
    top_after_scroll = page.evaluate_script("document.querySelector('#assistant_panel [role=\"log\"]').scrollTop")

    page.execute_script(<<~JS)
      const log = document.querySelector('#assistant_panel [role="log"]')
      const grown = document.createElement('div')
      grown.style.height = '2000px'
      grown.textContent = 'Antwort, die weiter waechst'
      log.appendChild(grown)
    JS

    # Give the follow every chance to misbehave before asserting that it did not.
    sleep 1
    expect(page.evaluate_script("document.querySelector('#assistant_panel [role=\"log\"]').scrollTop"))
      .to eq(top_after_scroll)
  end

  it 'keeps the composer inside the panel, reachable without scrolling the page' do
    panel = box('#assistant_panel [data-assistant-panel-target="panel"]')
    composer = box('#assistant_panel [data-neo-chat-composer-target="field"]')

    expect(composer['bottom']).to be <= panel['bottom']
    expect(composer['top']).to be >= panel['top']
    # And inside the viewport, which is the same statement from the user's side.
    expect(composer['bottom']).to be <= page.evaluate_script('window.innerHeight')
  end

  # The offset is the other half of "the panel does not cover the page". With
  # stylesheets on, this is where the media query and the custom property have to
  # meet; with them off (the other spec file) only the property can be asserted.
  it 'moves the page content clear of the panel' do
    eventually('main sits to the right of the panel') do
      box('main')['left'] >= box('#assistant_panel [data-assistant-panel-target="panel"]')['right']
    end
  end

  # The three-lane pages are where the panel meets the grid, and NO spec looked at
  # them until now -- neither the offset nor the L12 lane collapse had any
  # coverage on a page that actually has lanes. That blind spot is why a
  # descendant selector for the offset survived three reviews: it also hits the
  # SECOND <main> that NeoTwoColumnGridComponent renders as its content column,
  # pushing that column out of its own grid track.
  context 'on a three-lane page with a selected object' do
    let!(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, title: 'Ein gewaehltes Ticket')
      end
    end

    before do
      visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      eventually('the grid is on screen') { page.has_css?('.layout.two-column', wait: 0) }
    end

    it 'leaves the content column inside its own grid track' do
      grid = box('.layout.two-column')
      content = box('.layout.two-column main.column.content')

      # The content column may not start to the right of the grid it lives in.
      expect(content['left']).to be < grid['right']
      # ... and it has to be wide enough to hold something.
      expect(content['width']).to be > 300
    end

    # Both lanes open at once: the assistant on the outside, the page's own third
    # lane on the inside. The lane width used to be measured against the WINDOW
    # (36vw) while <main> had lost 636px to the panel, which left 175px for the
    # content. The lane classes are set directly rather than clicked, because the
    # geometry is the subject here, not the toggle.
    it 'leaves the content room when the page has a third lane open too' do
      page.execute_script("document.querySelector('.layout.two-column').classList.remove('hide-panel')")

      eventually('the third lane is laid out') do
        page.evaluate_script(
          "getComputedStyle(document.querySelector('.layout.two-column')).gridTemplateColumns"
        ).split(' ').size == 3
      end

      expect(box('.layout.two-column main.column.content')['width']).to be > 300
    end

    it 'collapses the list lane and keeps the content readable (L12)' do
      eventually('the list lane has yielded') do
        page.evaluate_script(
          "getComputedStyle(document.querySelector('.layout.two-column')).gridTemplateColumns"
        ).start_with?('0px')
      end

      expect(box('.layout.two-column main.column.content')['width']).to be > 300
    end
  end

  # --- the full view (S3c T2) -------------------------------------------------
  #
  # The chat frame moved INTO a grid with this ticket. The rules that keep the
  # transcript scrolling in its own box address `#assistant_panel_body >
  # turbo-frame`, so they should be untouched by that -- but "should be" is
  # exactly what the display:contents wrapper in T1 also looked like before it
  # broke these same two examples. So the full view gets asked the same
  # questions, with stylesheets on.
  # T-14 (Bezugs-Sammlung plan §12, §8.1). The one thing about the collapsing
  # reference list that only real CSS can settle: where the OPEN list lands.
  #
  # Both chips render as display:contents into a wrapping flex row, so the open
  # <details> is a flex ITEM of that row. Without `open:basis-full` it does not
  # break out -- it grows taller inside the row, and the scope chip, vertically
  # centred beside it, ends up wedged between the "Bezug" label and the list. The
  # class is pinned in the component spec; whether it actually does that can only
  # be measured with stylesheets on.
  describe 'a reference collection of more than one' do
    # TWO projects, because the scope chip only renders where there is a choice to
    # make (ScopeChipComponent#render?), and this cell is about what the open list
    # does TO that chip.
    let!(:referenced) do
      ActsAsTenant.with_tenant(organisation) do
        where = create(:project, organisation: organisation, name: 'Nordlicht Software')
        create(:project, organisation: organisation, name: 'Kundenportal v2')
        2.times.map do |i|
          create(:ticket, project: where, organisation: organisation, creator: user, title: "Aufgabe #{i}")
        end
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        long_thread.update_column(:scope_references, referenced.map do |ticket|
          Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)
        end)
      end
      # Revisited rather than set up before the first visit: the outer `before`
      # has already opened the panel, and the panel REMEMBERS that in a cookie --
      # so this second visit brings it back open, and clicking the trigger again
      # would close it.
      visit organisation_root_path(organisation_id: organisation.id)
      expect(page).to have_css('#assistant_panel .chat-context-row details summary')
    end

    # ⚠️ Measured while writing this, and worth writing down: at the default 380px
    # the context row ALREADY wraps with a reference set -- "Bezug [pill]" and
    # "Sucht in [select]" do not fit on one line -- so the scope chip sits below
    # the collection whether or not the list breaks out. Asserting "the chip
    # dropped below" as the proof would therefore have been true of every
    # implementation, `open:basis-full` removed included. What only the class can
    # do is give the OPEN element the full width of the row, so that is the claim
    # here; the rest follows from it and is asserted as consequence, not as proof.
    it 'gives the open list the full width of the row, with the field still below' do
      row = box('#assistant_panel .chat-context-row')

      closed = box('#assistant_panel .chat-context-row details')
      expect(closed['width']).to be < row['width']

      find('#assistant_panel .chat-context-row details summary').click

      eventually('the open list takes the full row width') do
        box('#assistant_panel .chat-context-row details')['width'] >= row['width'] - 1
      end
      opened = box('#assistant_panel .chat-context-row details')

      # Both entries are in it, and it is taller than the summary alone -- a
      # full-width box that is still one line high would satisfy the width claim
      # while showing nothing.
      expect(opened['height']).to be > closed['height']
      expect(page).to have_css('#assistant_panel .chat-context-row details form', count: 2)

      # The scope chip renders as display:contents, so its own element has no box;
      # its inner group is the flex item. Nothing of it sits INSIDE the list's
      # height.
      expect(box("#chat_#{long_thread.id}_scope_chip > div")['top']).to be >= opened['bottom'] - 1
      # And the reason the row lives above the field at all: a growing list pushes
      # the composer down, it never covers it or shoves it out of the panel.
      field = box('#assistant_panel [data-neo-chat-composer-target="field"]')
      panel = box('#assistant_panel')
      expect(field['top']).to be >= opened['bottom'] - 1
      expect(field['bottom']).to be <= panel['bottom']
    end
  end

  describe 'expanded' do
    before do
      find("#assistant_panel button[data-action='assistant-panel#expandToFull']").click
      expect(page).to have_css('.assistant-panel--full', visible: :all)
    end

    it 'reaches the right edge of the window instead of keeping the panel width' do
      panel = box('#assistant_panel [data-assistant-panel-target="panel"]')

      expect(panel['right']).to be_within(2).of(page.evaluate_script('window.innerWidth'))
      expect(panel['width']).to be > AssistantPanelState::MAX_WIDTH
    end

    # R-L1: on the page grid the list track would be minmax(380px, 2fr), roughly
    # 40 percent. Here the list is a column of one-line labels and the
    # conversation is the work, so the lane is narrow and capped.
    it 'gives the history lane a narrow track, not the page grid share' do
      eventually('the lane rendered') { page.evaluate_script("!!document.querySelector('#assistant_panel_history a, #assistant_panel_history p')") }

      lane = box('#assistant_panel_history')
      panel = box('#assistant_panel [data-assistant-panel-target="panel"]')

      expect(lane['width']).to be > 0
      expect(lane['width']).to be < panel['width'] / 3
    end

    it 'still scrolls the transcript inside its own container' do
      log = page.evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector('#assistant_panel [role="log"]')
          return { scrollHeight: el.scrollHeight, clientHeight: el.clientHeight,
                   overflowY: getComputedStyle(el).overflowY }
        })()
      JS

      expect(log['overflowY']).to eq('auto')
      expect(log['scrollHeight']).to be > log['clientHeight']
    end

    it 'still keeps the composer inside the panel' do
      panel = box('#assistant_panel [data-assistant-panel-target="panel"]')
      composer = box('#assistant_panel [data-neo-chat-composer-target="field"]')

      expect(composer['bottom']).to be <= panel['bottom']
      expect(composer['bottom']).to be <= page.evaluate_script('window.innerHeight')
    end
  end
end

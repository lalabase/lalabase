# frozen_string_literal: true

require 'rails_helper'

# The product screenshots for the project website.
#
# Not a test. Excluded from every normal run and from the CI; run it on purpose:
#
#   MARKETING_SCREENSHOTS=1 bundle exec rspec spec/marketing/screenshots_spec.rb
#
# It builds the Nordlicht fiction (Lalabase::Demo::World, the same world as the
# public demo) in the test database, freezes the clock and saves
# one picture per motif and language to tmp/screenshots/marketing/<locale>/. The
# website imports them from there; nothing of it is committed here.
#
# It fails loudly when a screen changes shape (a selector it waits for is gone), which
# is the point: a stale picture on the website is worse than a red run.
module MarketingScreenshots
  # A Wednesday morning: the week columns of the time list show Monday to today.
  NOW = Time.zone.local(2026, 10, 14, 10, 30)
  # The assistant shows without a real model behind it: the answer in the pictures
  # is stored, and a key that is never called only switches the panel on.
  ORGANISATION = { ai_enabled: true, assistant_enabled: true, ai_provider: 'openai',
                   ai_access_token: 'sk-fiction-0000000000000000' }.freeze
  OUTPUT = Rails.root.join('tmp/screenshots/marketing')
  # Wide enough that the ticket list shows names and dates in full.
  WIDTH = 1600
  HEIGHT = 1000
  # The window for pictures that end up in a tile: the list fills less width.
  TILE_WIDTH = 1100
  CLIP_MARGIN = 16
  # The assistant's collapsed state hovers over the bottom of every page. A picture
  # ends above it.
  CAPSULE = '#assistant_panel input[placeholder]'
end

Capybara.register_driver :marketing_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless=new')
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--disable-gpu')
  options.add_argument('--hide-scrollbars')
  options.add_argument("--window-size=#{MarketingScreenshots::WIDTH},#{MarketingScreenshots::HEIGHT}")
  # Twice the pixels, so the pictures stay sharp on a high-density screen.
  options.add_argument('--force-device-scale-factor=2')
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: LocalChrome.apply_binary(options))
end

RSpec.describe 'Marketing screenshots', :marketing_screenshots, type: :system do
  include ActiveSupport::Testing::TimeHelpers

  before do
    driven_by :marketing_chrome
    # The browser outlives the example: without this, the narrower window of the
    # assistant picture stays for every picture after it.
    page.driver.browser.manage.window.resize_to(MarketingScreenshots::WIDTH, MarketingScreenshots::HEIGHT)
    Prosopite.pause
    travel_to MarketingScreenshots::NOW
    set_browser_clock
  end

  after { Prosopite.resume }

  # The server lives at NOW (travel_to), the browser would live today: the session
  # check compares the two and calls the session expired, and every "2 days ago"
  # rendered in the browser would be off. This sets the browser's clock to NOW on
  # every page before any script of the page runs.
  def set_browser_clock
    real_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    offset = (MarketingScreenshots::NOW.to_f * 1000).to_i - real_ms
    page.driver.browser.execute_cdp('Page.addScriptToEvaluateOnNewDocument', source: <<~JS)
      (() => {
        const RealDate = Date
        const offset = #{offset}
        class ShiftedDate extends RealDate {
          constructor(...args) { args.length ? super(...args) : super(RealDate.now() + offset) }
          static now() { return RealDate.now() + offset }
        }
        globalThis.Date = ShiftedDate
      })()
    JS
  end

  # Saves the window from the top down to `until_bottom_of` (plus a margin), or down
  # to the assistant capsule when no element is named. `clip_to` narrows the picture to
  # one element's left, right and top edge: a tile on the website is a third of the
  # page wide, and the whole window shrunk to that is unreadable. The window is taken
  # whole and cut with libvips, which the core already carries for Active Storage.
  def capture(locale, motif, until_bottom_of: nil, clip_to: nil, margin: MarketingScreenshots::CLIP_MARGIN)
    dir = MarketingScreenshots::OUTPUT.join(locale.to_s)
    FileUtils.mkdir_p(dir)
    window = dir.join("#{motif}.window.png")
    settle
    page.driver.browser.save_screenshot(window.to_s)

    image = Vips::Image.new_from_file(window.to_s)
    scale = image.width.to_f / page.evaluate_script('window.innerWidth')
    left, top, right = clip_to ? clip_area(clip_to, image.width / scale, margin) : [0, 0, image.width / scale]
    bottom = [picture_bottom(until_bottom_of), image.height / scale].min
    area = [left, top, right - left, bottom - top].map { |value| (value * scale).round }
    image.crop(*area).write_to_file(dir.join("#{motif}.png").to_s)
    FileUtils.rm_f(window)
  end

  # The element's edges plus a margin, so text does not end flush at the cut.
  def clip_area(selector, window_width, margin)
    left, top, right = box(selector).values_at('left', 'top', 'right')
    [[left - margin, 0].max, [top - margin, 0].max, [right + margin, window_width].min]
  end

  def box(selector) = page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().toJSON()")

  # Waits until no transition or animation runs (the assistant expands with one), so a
  # second run takes the same picture.
  def settle
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script('document.getAnimations().every((a) => a.playState !== "running")')
    end
    sleep 0.2
  end

  # The sources of the answer in the open panel, unfolded.
  def open_citations(count)
    find('#assistant_panel [data-testid="citation-list"] summary').click
    expect(page).to have_css('#assistant_panel [data-testid="citation-row"]', count: count)
  end

  def picture_bottom(selector)
    if selector
      box(selector)['bottom'] + 32
    else
      capsule = page.evaluate_script(<<~JS)
        (() => { const el = document.querySelector(#{MarketingScreenshots::CAPSULE.to_json}); return el && el.closest('form, div').getBoundingClientRect().top })()
      JS
      (capsule || page.evaluate_script('window.innerHeight')) - 16
    end
  end

  %i[de en].each do |locale|
    context "in #{locale}" do
      let(:world) do
        Lalabase::Demo::World.new(locale:, now: MarketingScreenshots::NOW,
                                  organisation: MarketingScreenshots::ORGANISATION).build
      end

      before do
        ActsAsTenant.current_tenant = world.organisation
        sign_in world.signed_in
      end

      it 'takes the ticket list' do
        visit organisation_project_tickets_path(world.organisation, world.project(:deichblick))
        expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS.last.fetch(locale))
        capture(locale, :tickets)
      end

      # A narrower window and only the list, without the sidebar: the picture sits in
      # a tile on the website.
      it 'takes the time list' do
        page.driver.browser.manage.window.resize_to(MarketingScreenshots::TILE_WIDTH, MarketingScreenshots::HEIGHT)
        visit organisation_time_sessions_path(world.organisation, date_range: 'this_week')
        expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS[3].fetch(locale))
        capture(locale, :time, clip_to: '#timeSessions')
      end

      # The note the assistant cites, open next to the list.
      it 'takes the knowledge list with an open note' do
        visit organisation_project_knowledge_index_path(world.organisation, world.project(:deichblick),
                                                        note_id: world.notes.first.id)
        content = Lalabase::Demo::Fiction::NOTES.first[:content].fetch(locale)
        last_line = Nokogiri::HTML.fragment(Lalabase::Demo::Fiction.dated(content, locale, MarketingScreenshots::NOW))
                                  .css('p').last.text
        expect(page).to have_text(last_line)
        expect(page).to have_no_css('.layout.hide-content')
        capture(locale, :knowledge, clip_to: 'main.column.content', until_bottom_of: '#note-header')
      end

      # One ticket with its comments and the hours booked on it.
      it 'takes a ticket with its context' do
        ticket = world.ticket(Lalabase::Demo::Fiction::CHAT[:ticket])
        visit organisation_project_ticket_path(world.organisation, world.project(:deichblick), ticket)
        expect(page).to have_text(Lalabase::Demo::Fiction::COMMENTS.last.fetch(locale))
        capture(locale, :ticket)
      end

      # The tickets as a board: a setting per person and project, stored the way the
      # view switch stores it.
      it 'takes the ticket board' do
        ViewConfiguration.for_user_project(world.signed_in, world.project(:deichblick), 'tickets')
                         .update!(view_mode: 'kanban')
        visit organisation_project_tickets_path(world.organisation, world.project(:deichblick))
        expect(page).to have_css('.kanban-board')
        expect(page).to have_text(Lalabase::Demo::Fiction::TICKETS.last.fetch(locale))
        capture(locale, :board)
      end

      # The assistant beside the object it was asked about, with the object as its
      # reference: the ticket of the detail motif, and the weekly call. The open panel
      # reaches the bottom of the window, so the picture is the whole window.
      it 'takes the assistant beside the ticket' do
        ticket = world.ticket(Lalabase::Demo::Fiction::TICKET_QUESTION[:ticket])
        visit organisation_project_ticket_path(world.organisation, ticket.project, ticket,
                                               assistant_chat_id: world.ticket_question.id)
        # Three citations, two rows: the comment is listed under its ticket.
        open_citations(2)
        capture(locale, :ticket_assistant, until_bottom_of: 'body')
      end

      it 'takes the assistant beside the meeting' do
        meeting = world.meetings.fetch(Lalabase::Demo::Fiction::MEETING_QUESTION[:meeting])
        visit organisation_project_meeting_path(world.organisation, meeting.project, meeting,
                                                assistant_chat_id: world.meeting_question.id)
        open_citations(2)
        capture(locale, :meeting_assistant, until_bottom_of: 'body')
      end

      it 'takes the assistant answer with its sources' do
        # Narrower than the other pictures: in full mode the answer runs across the
        # whole window, and at 1600 px the picture came out four times as wide as tall.
        page.driver.browser.manage.window.resize_to(1200, MarketingScreenshots::HEIGHT)
        visit organisation_root_path(organisation_id: world.organisation.id,
                                     assistant_chat_id: world.chat.id, assistant: 'full')
        find('#assistant_panel [data-testid="citation-list"] summary').click
        expect(page).to have_css('#assistant_panel [data-testid="citation-row"]', count: 3)
        # The conversation only: the answer is what the row on the website is about.
        # No margin: around it are the borders of the neighbouring columns.
        capture(locale, :assistant, clip_to: '#assistant_panel_body', margin: 0,
                                    until_bottom_of: '#assistant_panel [data-testid="citation-list"]')
      end
    end
  end
end

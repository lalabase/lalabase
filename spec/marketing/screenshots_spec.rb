# frozen_string_literal: true

require 'rails_helper'
require_relative 'nordlicht_fiction'

# The product screenshots for the project website.
#
# Not a test. Excluded from every normal run and from the CI; run it on purpose:
#
#   MARKETING_SCREENSHOTS=1 bundle exec rspec spec/marketing/screenshots_spec.rb
#
# It builds the Nordlicht fiction in the test database, freezes the clock and saves
# one picture per motif and language to tmp/screenshots/marketing/<locale>/. The
# website imports them from there; nothing of it is committed here.
#
# It fails loudly when a screen changes shape (a selector it waits for is gone), which
# is the point: a stale picture on the website is worse than a red run.
module MarketingScreenshots
  OUTPUT = Rails.root.join('tmp/screenshots/marketing')
  # Wide enough that the ticket list shows names and dates in full.
  WIDTH = 1600
  HEIGHT = 1000
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
    Prosopite.pause
    travel_to NordlichtFiction::NOW
    set_browser_clock
  end

  after { Prosopite.resume }

  # The server lives at NOW (travel_to), the browser would live today: the session
  # check compares the two and calls the session expired, and every "2 days ago"
  # rendered in the browser would be off. This sets the browser's clock to NOW on
  # every page before any script of the page runs.
  def set_browser_clock
    real_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    offset = (NordlichtFiction::NOW.to_f * 1000).to_i - real_ms
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
  # to the assistant capsule when no element is named. The window is taken whole and
  # cut with libvips, which the core already carries for Active Storage.
  def capture(locale, motif, until_bottom_of: nil)
    dir = MarketingScreenshots::OUTPUT.join(locale.to_s)
    FileUtils.mkdir_p(dir)
    window = dir.join("#{motif}.window.png")
    settle
    page.driver.browser.save_screenshot(window.to_s)

    image = Vips::Image.new_from_file(window.to_s)
    scale = image.width.to_f / page.evaluate_script('window.innerWidth')
    height = [(picture_bottom(until_bottom_of) * scale).round, image.height].min
    image.crop(0, 0, image.width, height).write_to_file(dir.join("#{motif}.png").to_s)
    FileUtils.rm_f(window)
  end

  # Waits until no transition or animation runs (the assistant expands with one), so a
  # second run takes the same picture.
  def settle
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script('document.getAnimations().every((a) => a.playState !== "running")')
    end
    sleep 0.2
  end

  def picture_bottom(selector)
    if selector
      page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().bottom") + 32
    else
      capsule = page.evaluate_script(<<~JS)
        (() => { const el = document.querySelector(#{MarketingScreenshots::CAPSULE.to_json}); return el && el.closest('form, div').getBoundingClientRect().top })()
      JS
      (capsule || page.evaluate_script('window.innerHeight')) - 16
    end
  end

  %i[de en].each do |locale|
    context "in #{locale}" do
      let(:world) { NordlichtWorld.new(locale).build }

      before do
        ActsAsTenant.current_tenant = world.organisation
        sign_in world.person(:svenja)
      end

      it 'takes the ticket list' do
        visit organisation_project_tickets_path(world.organisation, world.project(:deichblick))
        expect(page).to have_text(NordlichtFiction::TICKETS.last.fetch(locale))
        capture(locale, :tickets)
      end

      it 'takes the time list' do
        visit organisation_time_sessions_path(world.organisation, date_range: 'this_week')
        expect(page).to have_text(NordlichtFiction::TICKETS[3].fetch(locale))
        capture(locale, :time)
      end

      # The note the assistant cites, open next to the list.
      it 'takes the knowledge list with an open note' do
        visit organisation_project_knowledge_index_path(world.organisation, world.project(:deichblick),
                                                        note_id: world.notes.first.id)
        last_line = Nokogiri::HTML.fragment(NordlichtFiction::NOTES.first[:content].fetch(locale)).css('p').last.text
        expect(page).to have_text(last_line)
        expect(page).to have_no_css('.layout.hide-content')
        capture(locale, :knowledge)
      end

      # One ticket with its comments and the hours booked on it.
      it 'takes a ticket with its context' do
        ticket = world.ticket(NordlichtFiction::CHAT[:ticket])
        visit organisation_project_ticket_path(world.organisation, world.project(:deichblick), ticket)
        expect(page).to have_text(NordlichtFiction::COMMENTS.last.fetch(locale))
        capture(locale, :ticket)
      end

      it 'takes the assistant answer with its sources' do
        # Narrower than the other pictures: in full mode the answer runs across the
        # whole window, and at 1600 px the picture came out four times as wide as tall.
        page.driver.browser.manage.window.resize_to(1200, MarketingScreenshots::HEIGHT)
        visit organisation_root_path(organisation_id: world.organisation.id,
                                     assistant_chat_id: world.chat.id, assistant: 'full')
        find('#assistant_panel [data-testid="citation-list"] summary').click
        expect(page).to have_css('#assistant_panel [data-testid="citation-row"]', count: 3)
        capture(locale, :assistant, until_bottom_of: '#assistant_panel [data-testid="citation-list"]')
      end
    end
  end
end

# Builds the fiction for one language. A class rather than let-blocks, so the order of
# writes is explicit: people before projects, projects before tickets, tickets before
# the hours booked on them.
class NordlichtWorld
  include FactoryBot::Syntax::Methods

  attr_reader :organisation, :chat, :notes

  def initialize(locale)
    @locale = locale
    @people = {}
    @projects = {}
    @tickets = []
  end

  def person(key) = @people.fetch(key)
  def project(key) = @projects.fetch(key)
  def ticket(index) = @tickets.fetch(index)

  def build
    @organisation = create(:organisation, name: 'Nordlicht Software GmbH', subdomain: 'nordlicht',
                                          domain: NordlichtFiction::DOMAIN, assistant_enabled: true,
                                          ai_provider: 'openai', ai_access_token: 'sk-fiction-0000000000000000')
    # The default smart folders take their names from the locale at creation, as they
    # do for a real person who creates a project in that language.
    I18n.with_locale(@locale) { build_inside }
    self
  end

  private

  def build_inside
    ActsAsTenant.with_tenant(@organisation) do
      role = create(:admin_role, organisation: @organisation)
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      NordlichtFiction::PEOPLE.each { |key, names| @people[key] = add_person(key, names, role) }
      NordlichtFiction::PROJECTS.each_key { |key| @projects[key] = add_project(key) }
      add_tickets
      add_time
      add_notes
      add_comments
      add_chat
    end
  end

  def add_person(key, names, role)
    user = create(:user, **names, email: NordlichtFiction.email(key), language_preference: @locale.to_s)
    create(:membership, user: user, organisation: @organisation, role: role, active: true)
    user
  end

  def add_project(key)
    entry = NordlichtFiction::PROJECTS.fetch(key)
    project = create(:project, organisation: @organisation, name: entry.fetch(@locale),
                               description: entry[:description].fetch(@locale), repository: nil)
    Projects::DefaultAttributeService.new(project).call
    Projects::DefaultSmartFolderService.new(project).call(person(:svenja))
    project
  end

  def add_tickets
    NordlichtFiction::TICKETS.each do |entry|
      params = { title: entry.fetch(@locale),
                 custom_attributes: { 'status' => entry[:status], 'priority' => entry[:priority] } }
      params[:assignee_ids] = [person(entry[:assignee]).id] if entry[:assignee]
      result = Actors::SaveTicket.call(project: project(:deichblick), params: params, current_user: person(:svenja))
      raise "Fiction ticket failed: #{result.errors.to_sentence}" unless result.success?

      @tickets << result.resource
    end
    # Created over the last weeks, oldest first, so the list does not say "less than a
    # minute ago" nine times.
    @tickets.each_with_index do |ticket, index|
      at = NordlichtFiction::NOW - ((@tickets.size - index) * 3).days
      ticket.update_columns(created_at: at, updated_at: at)
    end
  end

  def add_time
    NordlichtFiction::TIME.each do |entry|
      create(:time_session, organisation: @organisation, project: project(:deichblick),
                            ticket: entry[:ticket] && @tickets.fetch(entry[:ticket]),
                            creator: person(entry[:person]), duration: entry[:minutes],
                            occurred_on: NordlichtFiction::NOW - entry[:days_ago].days,
                            description: entry.fetch(@locale))
    end
  end

  def add_notes
    @notes = NordlichtFiction::NOTES.map do |entry|
      create(:note, organisation: @organisation, project: project(:deichblick), creator: person(:svenja),
                    title: entry.fetch(@locale), content: entry[:content].fetch(@locale),
                    description: nil, create_embeddings: false)
    end
    @notes.each_with_index do |note, index|
      at = NordlichtFiction::NOW - (index + 1).weeks
      note.update_columns(created_at: at, updated_at: at)
    end
  end

  def add_comments
    ticket = @tickets.fetch(NordlichtFiction::CHAT[:ticket])
    NordlichtFiction::COMMENTS.each do |entry|
      post = create(:post, ticket: ticket, organisation: @organisation, user: person(entry[:person]),
                           content: entry.fetch(@locale), create_embeddings: false)
      at = NordlichtFiction::NOW - entry[:hours_ago].hours
      post.update_columns(created_at: at, updated_at: at)
    end
  end

  # The first post of a chat renders as the question (Chatpost#set_initial_role makes it
  # 'system'). model_used marks the answer as finished; without it the [n] links stay text.
  def add_chat
    spec = NordlichtFiction::CHAT
    svenja = person(:svenja)
    @chat = create(:chat, organisation: @organisation, user: svenja)
    @chat.chatposts.first.update!(user: svenja, content: spec[:question].fetch(@locale))
    citations = [Lalabase::Citations.ticket(@tickets.fetch(spec[:ticket])),
                 Lalabase::Citations.time_report(project(:deichblick), {}),
                 Lalabase::Citations.note(@notes.fetch(spec[:note]))]
    create(:chatpost, chat: @chat, organisation: @organisation, user: svenja, role: 'assistant',
                      content: spec[:answer].fetch(@locale), model_used: 'mistral-medium-latest',
                      source_citations: citations.map(&:deep_stringify_keys))
    # A fixed moment instead of "less than a minute ago", which flips while the run takes.
    @chat.chatposts.update_all(created_at: NordlichtFiction::NOW - 20.minutes)
  end
end

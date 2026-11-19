# frozen_string_literal: true

require 'rails_helper'

# What: every list row in one form (user, 2026-11-19): its surface (hover, the open row)
#       ends at the list's lines, never beyond them, and its content stands --row-inset
#       (layout.css, 12 px) inside, left and right. The column heads take the same inset.
#       The ticket list on a phone stays flush: there is less room.
# Why:  until then every list had an inset of its own: the tables 12 px (the tickets 0 on
#       the left), People, Inbox and Glossar 8 px with a surface 8 px beyond the lines,
#       the people of all organisations 0 and 16, the members 0, the times 8. Measured in
#       a browser, because a padding in a class says nothing about where the row stands.
#       The times on a phone stay flush as well: they are cards like the tickets there.
RSpec.describe 'The inset of a list row', :js, type: :system do
  let(:organisation) { create(:organisation) }
  let(:second) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Beispiel') }
  let(:project) { create(:project, organisation: organisation) }
  let(:inset) { 12 }

  before do
    Prosopite.pause
    ActsAsTenant.with_tenant(second) do
      create(:membership, user: user, organisation: second, role: create(:admin_role, organisation: second), active: true)
    end
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    create(:person, organisation: organisation, name: 'Berta Erste')
    ticket = create(:ticket, project: project, title: 'Erstes Ticket', creator: user)
    create(:meeting, project: project, title: 'Planung', creator: user, occurred_at: 2.days.ago)
    create(:note, project: project, organisation: organisation, creator: user, title: 'Notiz eins')
    create(:glossary_term, organisation: organisation, term: 'Zorbelstein')
    create(:time_session, project: project, organisation: organisation, creator: user, ticket: ticket)
    create(:activity, trackable: ticket, actor: user, organisation: organisation)
    create(:notification, recipient: user, organisation: organisation, project: project, notifiable: ticket, actor: user,
                          channel: 'in_app', state: :delivered)
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  # The row's surface against its list (a table, a list), and where its content starts and
  # ends inside it: a table row by its first and last visible cell, any other row by its padding.
  let(:measure_script) do
    <<~JS
      (row) => {
        const r = row.getBoundingClientRect();
        const list = row.closest('table, ul, ol') || row.parentElement;
        const l = list.getBoundingClientRect();
        let start, end;
        if (row.tagName === 'TR') {
          const cells = [...row.children].filter(cell => getComputedStyle(cell).display !== 'none' && cell.getBoundingClientRect().width > 0);
          const first = cells[0], last = cells[cells.length - 1];
          // Where the first cell's visible content begins: a box centred in a fixed column
        // (the tickets' select column) has no padding and still stands inside. Content is
        // text, a control, a picture, or a box with an edge or a fill (an avatar without a
        // photo); nothing out of the flow (.sr-only, a popover) and nothing invisible.
        const outOfFlow = (element) => {
          for (let e = element; e && e !== first; e = e.parentElement) {
            if (['absolute', 'fixed'].includes(getComputedStyle(e).position)) return true;
          }
          return false;
        };
        const seen = (element) => element.checkVisibility({ opacityProperty: true, visibilityProperty: true }) && !outOfFlow(element);
        const lefts = [];
        const walker = document.createTreeWalker(first, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (node.nodeType === 3) {
            if (!node.textContent.trim() || !seen(node.parentElement)) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            lefts.push(range.getBoundingClientRect().left);
            continue;
          }
          if (!seen(node) || node.getBoundingClientRect().width === 0) continue;
          const style = getComputedStyle(node);
          const boxed = parseFloat(style.borderLeftWidth) > 0 || style.backgroundColor !== 'rgba(0, 0, 0, 0)';
          if (boxed || ['INPUT', 'IMG', 'SVG', 'I'].includes(node.tagName.toUpperCase())) lefts.push(node.getBoundingClientRect().left);
        }
        start = Math.min(...lefts) - r.left;
          end = r.right - (last.getBoundingClientRect().right - parseFloat(getComputedStyle(last).paddingRight));
        } else {
          start = parseFloat(getComputedStyle(row).paddingLeft);
          end = parseFloat(getComputedStyle(row).paddingRight);
        }
        return [Math.round(l.left - r.left), Math.round(r.right - l.right), Math.round(start), Math.round(end)];
      }
    JS
  end

  def measure(selector)
    row = first(selector, minimum: 1)
    row.evaluate_script("(#{measure_script})(this)")
  end

  def on_a_phone
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 430, height: 900, deviceScaleFactor: 1, mobile: true)
    yield
  ensure
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
  end

  routes = Rails.application.routes.url_helpers
  {
    'Tickets' => [->(o, p) { routes.organisation_project_tickets_path(o, p) }, 'tr.ticket-row'],
    'Wissen' => [->(o, p) { routes.organisation_project_knowledge_index_path(o, p) }, 'tr[data-controller~="list-row"]'],
    'Meetings' => [->(o, p) { routes.organisation_project_meetings_path(o, p) }, '[data-controller~="list-row"]'],
    'Alle Meetings' => [->(o, _p) { routes.organisation_meetings_path(o) }, '[data-controller~="list-row"]'],
    'Glossar' => [->(o, _p) { routes.organisation_glossary_terms_path(o) }, '[data-controller~="list-row"]'],
    'Personen' => [->(o, _p) { routes.organisation_people_path(o) }, '.people-row'],
    'Inbox' => [->(o, _p) { routes.organisation_notifications_path(o) }, '.inbox-row'],
    'Gesamt-Inbox' => [->(_o, _p) { routes.all_inboxes_path }, '.inbox-row'],
    'Personen aller Organisationen' => [->(_o, _p) { routes.all_people_path }, 'tr[data-all-people-row]'],
    'Mitglieder' => [->(o, _p) { routes.organisation_memberships_path(o) }, 'tr.members-row'],
    'Aktivitäten' => [->(o, p) { routes.organisation_project_activities_path(o, p) }, '[data-activity-target-id]'],
    'Zeiten' => [->(o, _p) { routes.organisation_time_sessions_path(o) }, '[data-time-session-bulk-group] > div']
  }.each do |name, (path, selector)|
    it "#{name}: the row ends at the lines and its content stands 12 px inside" do
      page.current_window.resize_to(1440, 1000)
      visit instance_exec(organisation, project, &path)

      expect(measure(selector)).to eq([0, 0, inset, inset])
    end

    next if %w[Tickets Zeiten].include?(name)

    it "#{name} on a phone: the same" do
      on_a_phone do
        visit instance_exec(organisation, project, &path)

        expect(measure(selector)).to eq([0, 0, inset, inset])
      end
    end
  end

  {
    'Tickets' => [->(o, p) { routes.organisation_project_tickets_path(o, p) }, '.mobile-ticket-row'],
    'Zeiten' => [->(o, _p) { routes.organisation_time_sessions_path(o) }, '[data-time-session-bulk-group] > div']
  }.each do |name, (path, selector)|
    it "#{name} on a phone: the rows stay flush, there is less room" do
      on_a_phone do
        visit instance_exec(organisation, project, &path)

        expect(measure(selector)).to eq([0, 0, 0, 0])
      end
    end
  end

  # The heads stand over what they name: the word "Name" over the names, "Zuletzt" ending
  # where the dates end.
  it 'Personen: the column heads take the inset of the rows' do
    page.current_window.resize_to(1440, 1000)
    visit organisation_people_path(organisation)

    name_head = find('.people-columns__head--name a').evaluate_script('this.getBoundingClientRect().left')
    name = first('.people-row .people-row__name').evaluate_script('this.getBoundingClientRect().left')
    expect(name_head).to be_within(0.5).of(name)
    last_head = find('.people-columns__head--last').evaluate_script('this.getBoundingClientRect().right')
    last = first('.people-row .people-row__last').evaluate_script('this.getBoundingClientRect().right')
    expect(last_head).to be_within(0.5).of(last)
  end
end

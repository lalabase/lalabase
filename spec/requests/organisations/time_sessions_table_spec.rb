# frozen_string_literal: true

require 'rails_helper'

# What: the rendered time list after the redesign: month > row > booking.
# Type: Request spec.
# Why:  T8 of doc/projektzeiten_tabelle_plan.md. The numbers were pinned in S1
#       and S2; this pins that they reach the screen, that a row can be opened at
#       all (edit and delete live inside it now), and that the phone shows the
#       same bar and the same word as the desktop.
RSpec.describe 'Organisations::TimeSessions table', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) { create(:user) }
  let(:colleague) { create(:user) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:august) { Time.utc(2026, 8, 15, 10, 0) }
  let(:mobile_marker) { '<!-- Mobile: Card View -->' }

  before do
    ActsAsTenant.current_tenant = organisation
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: colleague, organisation: organisation, active: true)
    end
    Prosopite.pause
    sign_in admin
  end

  after { Prosopite.resume }

  def book(minutes, on: august, ticket: nil, in_project: project, creator: admin, group: nil, billed: false, description: 'Eine Buchung')
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: in_project, creator: creator,
                            duration: minutes, occurred_on: on, ticket: ticket, description: description,
                            time_session_group: group, billed: billed)
    end
  end

  def ticket_with(title)
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: title) }
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, date_range: 'all', **params)
  end

  # The list hides invoiced time by default ("what is still pending billing?"),
  # so an example about an invoiced booking has to ask for it.
  def get_list_with_billed(**params)
    get_list(status_filters: TimeSession::BILLING_STATUS_FILTERS, **params)
  end

  def desktop
    response.body.split(mobile_marker).first
  end

  def mobile
    response.body.split(mobile_marker).last
  end

  describe 'the month header' do
    it 'names the month and sums the rows under it' do
      book(60, ticket: ticket_with('Erstes'))
      book(30, ticket: ticket_with('Zweites'))

      get_list

      expect(desktop).to include('August 2026')
      expect(desktop).to include('01:30')
    end
  end

  describe 'a row' do
    it 'shows duration, reference and title' do
      ticket = ticket_with('Wires anpassen')
      book(75, ticket: ticket)

      get_list

      expect(desktop).to include('01:15')
      expect(desktop).to include("##{ticket.number}")
      expect(desktop).to include('Wires anpassen')
    end

    # The mark and the word say the same thing, on purpose: the mark alone was a
    # code with three dimensions and no legend, which nobody learns by using it
    # (design review, 30.08.2026). The word teaches it in passing.
    it 'carries the state as a mark AND names it beside the row' do
      ticket = ticket_with('Marke und Wort')
      book(75, ticket: ticket)

      get_list
      row = desktop[/data-time-session-bulk-group.*?data-ticket-group-target="sessions"/m]
      visible = Nokogiri::HTML::DocumentFragment.parse(row).text

      # The words come from their owner (S1), not from a literal here.
      expect(row).to include("aria-label=\"#{I18n.t('views.time_sessions.billing_status.without_billing')}: 01:15\"")
      expect(visible).to include(I18n.t('views.time_sessions.billing_status.without_billing'))
    end

    # The billing NAME is a different thing and stays one level down: a row can
    # span several, and the slug is long.
    it 'leaves the billing name to the bookings' do
      group = ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation, name: 'aug-slug') }
      book(60, ticket: ticket_with('Mit Abrechnung'), group: group)

      get_list
      row = desktop[/data-time-session-bulk-group.*?data-ticket-group-target="sessions"/m]

      expect(Nokogiri::HTML::DocumentFragment.parse(row).text).not_to include('aug-slug')
      expect(desktop).to include('aug-slug')
    end

    it 'says how much the filter is hiding, and only when it hides something' do
      ticket = ticket_with('Teilweise sichtbar')
      book(60, ticket: ticket, description: 'Findewort')
      book(90, ticket: ticket, description: 'nicht gesucht')

      get_list(search: 'Findewort')
      expect(desktop).to include('01:00 von 02:30')
      expect(desktop).to include('01:30')

      get_list
      expect(desktop).not_to include('von 02:30')
    end

    it 'carries the project name in the organisation-wide list, also without a subject' do
      other = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Zweitprojekt') }
      book(60, in_project: other)

      get_list

      expect(desktop).to include('Ohne Bezug')
      expect(desktop).to include('Zweitprojekt')
    end

    it 'draws the share bar with the minutes in its label' do
      ticket = ticket_with('Gemischt')
      group = ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation, name: 'aug-2026') }
      book(60, ticket: ticket)
      book(60, ticket: ticket, group: group, billed: true)

      get_list_with_billed

      expect(desktop).to include("aria-label=\"#{I18n.t('views.time_sessions.billing_status.billed')}: 01:00 · #{I18n.t('views.time_sessions.billing_status.without_billing')}: 01:00\"")
      # The share used to stand beside the bar as "teilweise 50 %". That column is
      # gone; the proportion is what the bar shows and the minutes are in its
      # label. The billing name is named on the bookings.
      expect(desktop).to include('aug-2026')
    end
  end

  # Found while reading the mobile partials on 30.08.2026, not by a failing test.
  # Neo::Buttons::IconButtonComponent reads `confirm:` as a TOP-LEVEL kwarg and
  # renders it as turbo_confirm; the mobile card passed it inside `form:`, where
  # nothing reads it. Nothing raised, nothing looked wrong: the dialog simply
  # never appeared, so on a phone the delete fired on the first tap. The desktop
  # line passes it at the top level and always had the dialog, which is why the
  # difference survived. Pinned on BOTH surfaces, because one of them having it
  # is exactly how this went unnoticed.
  describe 'deleting a booking' do
    it 'asks first, on the desktop line and on the phone card alike' do
      ticket = ticket_with('Loeschbar')
      book(30, ticket: ticket)

      get_list(expand_all: '1')
      word = I18n.t('views.confirm.delete_time_session')

      expect(desktop).to include(%(data-turbo-confirm="#{word}"))
      expect(mobile).to match(/data-turbo-confirm="[^"]+"/)
    end
  end

  # The page-load fallback hrefs of the pills. They used to be five hand-rolled
  # "#{request.path}?#{...to_query}" strings across two partials, which is the
  # shape Brakeman's LinkToHref check flags: a visitor-supplied query string next
  # to a path in one interpolated string. Frozen unchecked in the 27.08.2026
  # baseline and named in CLAUDE.md; cleared here because the file was open
  # anyway, and the ignore file is one entry shorter for it.
  # The panel comes in from the RIGHT on a wide screen and from the BOTTOM on a
  # phone (user, 30.08.2026): a full-width sheet rising out of the bottom edge
  # covers the very rows the reader has just picked.
  describe 'the assignment panel' do
    # One request per example, not one per call. Both helpers used to fetch the
    # page again, so an example reading the panel twice paid for two full
    # renders of the whole list.
    def rendered_page
      @rendered_page ||= begin
        get_list
        response.body
      end
    end

    def panel
      rendered_page[/<div id="bulk-action-bar".*?data-time-session-bulk-url="[^"]*"/m]
    end

    # The panel's own markup, bounded at BOTH ends. It used to run to the end of
    # the page on the grounds that nothing followed it, which stopped being true
    # the moment the panel moved out of the frame: an unbounded slice quietly
    # swallowed the rest of the page, and a "the panel has no select" assertion
    # was really asking about every select below it too.
    def panel_body
      body = rendered_page
      from = body.index('<div id="bulk-action-bar"')
      to   = body.index(I18n.t('views.organisations.time_sessions.index_table.assign_button'), from)
      # A nil end marker would make this an endless range and silently widen the
      # slice back to end-of-page — the exact vacuum this helper exists to prevent.
      raise 'assignment panel end marker not found' if to.nil?

      body[from..to]
    end

    it 'is a sheet at the bottom on a phone and a lane of its own on a wide screen' do
      book(30, ticket: ticket_with('Irgendwas'))

      markup = panel

      expect(markup).to include('fixed inset-x-0 bottom-0')
      expect(markup).to include('lg:sticky')
      expect(markup).to include('lg:w-[420px]')
    end

    # The phone's bottom navigation sits at z-mobile-nav (80) and floats exactly
    # over the sheet's own stacked Abbrechen/Zuweisen buttons. At z-modal (50)
    # they were behind it: the sheet opened and its actions could not be pressed.
    it 'clears the phone navigation instead of hiding under it' do
      book(30, ticket: ticket_with('Irgendwas'))

      classes = panel[/class="([^"]*)"/m, 1].to_s.split

      expect(classes).to include('z-mobile-nav')
      expect(classes).not_to include('z-modal')
    end

    # A cap on the BASE, not only from md up: without one the sheet grows past the
    # top of the screen and takes the title and the closing cross with it, on the
    # screen where there is no other way to close it.
    # The cap is what BOUNDS the column. The scrolling happens one level in, so
    # the root must not carry overflow of its own: that is what put the buttons
    # below the fold.
    it 'bounds its own height on a phone, not only on a wide screen' do
      book(30, ticket: ticket_with('Irgendwas'))

      classes = panel[/class="([^"]*)"/m, 1].to_s.split

      expect(classes.grep(/\Amax-h-/)).not_to be_empty
      expect(classes).to include('flex', 'flex-col')
      expect(classes).not_to include('overflow-y-auto')
    end

    # What makes it a LANE and not a layer: the frame is a flex column that gives
    # way, and the panel is its sibling AFTER it. Rendered before the frame it
    # would sit on the left; positioned absolutely it would cover the rows the
    # reader has just ticked, which is what it did until 30.08.2026.
    it 'follows the list inside a flex row, so the list gives way for it' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list
      body = response.body

      expect(body).to include('lg:flex lg:items-start lg:gap-6')
      expect(body.index('id="time_sessions_list_frame"')).to be < body.index('<div id="bulk-action-bar"')
    end

    # The panel and its controller sit AROUND the frame, not inside it. Inside,
    # every filter, page and sort replaced them, so the panel closed and the
    # selection was gone. Pinned by nesting, because "outside" is the whole point
    # and nothing about the rendered page says so otherwise.
    it 'keeps the panel and its controller outside the frame that reloads' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list
      body = response.body
      frame_at  = body.index('id="time_sessions_list_frame"')
      frame_end = body.index('</turbo-frame>', frame_at)

      expect(body.index('data-controller="time-session-bulk"')).to be < frame_at
      expect(body.index('<div id="bulk-action-bar"')).to be > frame_end
    end

    # The check above only means something while there is ONE frame with this id.
    # There used to be two, nested, both called time_sessions_list_frame: invalid
    # HTML, and it made "inside or outside the frame" unanswerable. A probe that
    # moved the panel back inside stayed green because of it.
    it 'renders exactly one frame by that name' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list

      expect(response.body.scan('id="time_sessions_list_frame"').size).to eq(1)
      expect(response.body.scan('</turbo-frame>').size).to eq(response.body.scan('<turbo-frame').size)
    end

    # The panel lists what is about to be taken over. The rows are folded by
    # default, so ticking a row picks bookings the reader cannot see; the list is
    # where they become visible and where one can be dropped again.
    it 'carries the machinery for the list of what is being taken over' do
      book(30, ticket: ticket_with('Irgendwas'), description: 'Reproduktion und Fix')

      markup = panel_body

      expect(markup).to include('data-time-session-bulk-target="selectionList"')
      expect(markup).to include('data-time-session-bulk-target="selectionSummary"')
    end

    # The list is rendered from the checkboxes, and a booking has TWO of them:
    # the desktop table and the phone cards are both in the DOM, one hidden by
    # CSS. This is the fact renderSelection deduplicates against; without it the
    # panel lists everything twice.
    it 'renders a checkbox for the same booking on both surfaces' do
      session = book(30, ticket: ticket_with('Irgendwas'), description: 'Reproduktion und Fix')

      get_list(expand_all: '1')

      expect(desktop).to include(%(value="#{session.id}"))
      expect(mobile).to include(%(value="#{session.id}"))
    end

    # Each booking checkbox carries its own short name, so the panel does not
    # have to walk the DOM for one and cannot pick up a neighbouring row's.
    it 'gives every booking checkbox the name the list will show' do
      book(30, ticket: ticket_with('Irgendwas'), description: 'Reproduktion und Fix')

      get_list(expand_all: '1')

      expect(desktop).to include('data-label="Reproduktion und Fix"')
      # Both surfaces, like the confirm dialog above: one of them carrying the
      # seam is exactly how a missing one goes unnoticed.
      expect(mobile).to include('data-label="Reproduktion und Fix"')
    end

    # Each option shows only its own field, and only while it is chosen: two open
    # fields ask the reader to work out which one the radio above makes count.
    # Asserted on the class LIST, not on a literal class string: the padding and
    # the order of these utilities are layout, and a spec that breaks when a
    # margin changes teaches people to stop reading it.
    # The input is parsed, not sliced: a data-action contains "->", so a
    # /<input[^>]*>/ stops at the arrow and silently returns half a tag.
    def billing_option
      Nokogiri::HTML::DocumentFragment.parse(panel_body)
                                      .at_css('[data-time-session-bulk-target="existingGroupOption"]')
    end

    def panel_node
      Nokogiri::HTML(rendered_page).at_css('#bulk-action-bar')
    end

    # The header, found through the title's own target rather than through its
    # Tailwind margin: a spacing change once broke two examples that had nothing
    # to do with spacing.
    def panel_header
      Nokogiri::HTML::DocumentFragment.parse(panel_body)
                                      .at_css('[data-time-session-bulk-target="panelTitle"]')
                                      .parent
    end

    def field_classes(markup, target)
      markup[/class="([^"]*)"[^>]*data-time-session-bulk-target="#{target}"/, 1].to_s.split
    end

    # The billings are on screen the moment the panel opens. There is no longer a
    # kind to choose first: the list IS the choice, and the new-billing row is a
    # member of it. Only that row's name field waits to be asked for.
    it 'shows the billings straight away and keeps only the name field back' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(30, ticket: ticket_with('Irgendwas'))

      panel = Nokogiri::HTML::DocumentFragment.parse(panel_body)

      expect(panel.at_css('[data-time-session-bulk-target="existingGroupOption"]')).to be_present
      expect(panel.css('[data-time-session-bulk-target="existingGroupOption"]')
                  .map { |o| o['disabled'] }).to all(be_nil)
      expect(field_classes(panel_body, 'newGroupField')).to include('hidden')
    end

    # The panel is a bounded COLUMN: the header and the buttons are fixed ends and
    # only what is between them scrolls. It used to be one scroll box holding
    # three independently capped lists, and nothing budgeted for the header, the
    # summaries, the total and the buttons on top of those caps. Every list kept
    # to its cap and the panel overflowed anyway: measured at a 760px viewport,
    # "Zuweisen" left the visible area at the ELEVENTH selected booking.
    #
    # Structure, not arithmetic, so this pins the structure. A cap coming back on
    # either growing list is the arithmetic creeping back in.
    it 'keeps the buttons and the title out of the scrolling middle' do
      book(30, ticket: ticket_with('Irgendwas'))

      root   = panel_node
      scroll = root.at_css('[data-time-session-bulk-target="selectionList"]')
                   .ancestors('div.overflow-y-auto').first

      # The root bounds the column and does not scroll itself.
      expect(root.classes).to include('flex', 'flex-col')
      expect(root.classes).not_to include('overflow-y-auto')

      # One scroll region, and neither end is inside it. By TARGET, not by the
      # button's label: the label is where panel_body's slice ends, so asking for
      # it asks a question of text that was cut off.
      expect(scroll).to be_present
      expect(scroll.at_css('[data-time-session-bulk-target="panelTitle"]')).to be_nil
      expect(scroll.at_css('[data-time-session-bulk-target="submitButton"]')).to be_nil
      expect(root.at_css('[data-time-session-bulk-target="submitButton"]')).to be_present
    end

    # The two lists that grow with the reader's work carry no cap of their own any
    # more. One did, and it is what made the overflow look accounted for.
    it 'leaves the growing lists uncapped, since the column holds the buttons' do
      book(30, ticket: ticket_with('Irgendwas'))

      panel = Nokogiri::HTML::DocumentFragment.parse(panel_body)

      %w[selectionList alreadyList].each do |target|
        classes = panel.at_css(%([data-time-session-bulk-target="#{target}"])).classes
        expect(classes.grep(/^max-h-/)).to be_empty, "#{target} carries a cap again"
        expect(classes).not_to include('overflow-y-auto'), "#{target} scrolls on its own again"
      end
    end

    # The escape hatch shares the billings' radio group, which is what makes the
    # panel one choice, and sits OUTSIDE the scrolling list, which is what keeps
    # it reachable when there are more billings than fit.
    it 'pins the new-billing row under the scrolling list, in the same radio group' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(30, ticket: ticket_with('Irgendwas'))

      panel   = Nokogiri::HTML::DocumentFragment.parse(panel_body)
      new_row = panel.at_css('[data-time-session-bulk-target="newGroupOption"]')
      list    = panel.at_css('[data-time-session-bulk-target="existingGroupOption"]').ancestors('ul').first

      expect(new_row['name']).to eq('existing_group_id')
      expect(list.at_css('[data-time-session-bulk-target="newGroupOption"]')).to be_nil

      targets = panel.css('[data-time-session-bulk-target]').map { |n| n['data-time-session-bulk-target'] }
      expect(targets.index('newGroupOption')).to be > targets.index('existingGroupOption')
    end

    # A booking can already be in the billing it is being assigned to: the list
    # lets you pick one out of billing X and hand it to billing X again. Not an
    # error, but not a transfer either, so it is listed apart and left out of the
    # arithmetic. The split is the controller's; this pins the two seams it needs.
    it 'tells each checkbox which billing its booking is already in' do
      group = ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(45, ticket: ticket_with('Schon drin'), group: group)

      get_list(expand_all: '1')

      expect(desktop).to include(%(data-group-id="#{group.id}"))
      expect(mobile).to include(%(data-group-id="#{group.id}"))
    end

    it 'carries a second list for what is already there' do
      book(30, ticket: ticket_with('Irgendwas'))

      markup = panel_body

      expect(markup).to include('data-time-session-bulk-target="alreadyList"')
      expect(markup).to include('data-time-session-bulk-target="alreadySummary"')
      expect(field_classes(markup, 'alreadyPanel')).to include('hidden')
    end

    # Each billing carries its own minutes, so the panel can say what it BECOMES
    # without asking the server again: the reader would otherwise add the
    # header's selection total to the line's total in their head, every time, to
    # answer the only question they came with. The arithmetic is the controller's;
    # this pins the seam it reads, and that the number is the same one the line
    # already prints.
    it 'gives each billing its minutes and a place for the resulting total' do
      group = ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(45, ticket: ticket_with('Schon drin'), group: group)
      book(30, ticket: ticket_with('Noch frei'))

      expect(billing_option['data-minutes']).to eq('45')
      expect(panel_body).to include('00:45')
      expect(panel_body).to match(/<span class="hidden[^"]*" data-billing-result>/)
    end

    # The sum of what is about to be taken over sits at the FOOT of that list,
    # in the same 46px slot the single durations use, so it stands under the
    # column it adds up. It used to be in the panel's heading, where it counted
    # the WHOLE selection, already-filed bookings included, and so named a number
    # the panel never assigns.
    it 'foots the list with a total in the durations column' do
      book(30, ticket: ticket_with('Irgendwas'))

      panel = Nokogiri::HTML::DocumentFragment.parse(panel_body)
      total = panel.at_css('[data-time-session-bulk-target="selectionTotal"]')
      list  = panel.at_css('[data-time-session-bulk-target="selectionList"]')

      expect(total).to be_present
      expect(total.classes).to include('w-[46px]', 'font-mono')

      # Outside the scrolling list, and after it: inside, the one number the
      # reader came for would scroll away with the rows.
      expect(list.at_css('[data-time-session-bulk-target="selectionTotal"]')).to be_nil
      targets = panel.css('[data-time-session-bulk-target]').map { |node| node['data-time-session-bulk-target'] }
      expect(targets.index('selectionTotal')).to be > targets.index('selectionList')
    end

    # Heading, list and total go together, so they hang on ONE wrapper. With the
    # total outside it, a selection holding nothing but already-filed bookings
    # would show "Summe 00:00" under an empty list.
    it 'keeps heading, list and total under one wrapper' do
      book(30, ticket: ticket_with('Irgendwas'))

      taken = Nokogiri::HTML::DocumentFragment.parse(panel_body)
                                              .at_css('[data-time-session-bulk-target="takenPanel"]')

      expect(taken).to be_present
      %w[selectionSummary selectionList selectionTotal].each do |target|
        expect(taken.at_css(%([data-time-session-bulk-target="#{target}"]))).to be_present, target
      end
    end

    # Closing a panel destroys nothing, so the cross is a bare glyph like every
    # other panel and modal in this app, not a red danger button. Pinned in both
    # directions: the glyph has to be there, and it must not come back wearing a
    # fill that promises a deletion.
    it 'closes with a bare cross, not a danger button' do
      book(30, ticket: ticket_with('Irgendwas'))

      header = panel_header.to_html

      expect(header).to include('bi bi-x-lg')
      expect(header).not_to include('bg-red-')
    end

    # The panel names a count ONCE, in the sentence over the list that also says
    # what becomes of those rows. It used to say it in the header as well, and
    # the two disagreed: the header counted the whole selection, the sentence
    # only what actually moves (user, 31.08.2026).
    it 'says nothing but its title in the header' do
      book(30, ticket: ticket_with('Irgendwas'))

      expect(panel_header.text.strip)
        .to eq(I18n.t('views.organisations.time_sessions.index_table.panel_title'))
    end

    # When the last row is dropped there is no remove button left to take the
    # focus, so the title takes it. focus() on an element that is not focusable
    # does nothing, silently, and this is the one moment a keyboard reader
    # depends on it, which is why the tabindex is in the markup and not set from
    # the controller.
    it 'makes the title focusable for the moment the last row is dropped' do
      book(30, ticket: ticket_with('Irgendwas'))

      title = Nokogiri::HTML::DocumentFragment.parse(panel_body)
                                              .at_css('[data-time-session-bulk-target="panelTitle"]')

      expect(title).to be_present
      expect(title['tabindex']).to eq('-1')
    end

    # The billings are a LIST, not a dropdown (design draft): a select hides the
    # choices behind one more click and shows only the one already picked. Each
    # line carries the time that billing already holds, which is the number that
    # helps somebody pick; the draft's "offen"/"eingereicht" column has no
    # counterpart here, and this list holds only unbilled billings anyway.
    it 'lists the open billings with what each already holds' do
      group = ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(90, ticket: ticket_with('Schon zugeordnet'), group: group)
      book(30, ticket: ticket_with('Noch frei'))

      markup = panel_body

      expect(markup).to include('data-time-session-bulk-target="existingGroupOption"')
      expect(markup).to include('aug-2026')
      expect(markup).to include('01:30')
      expect(markup).not_to include('<select')
    end

    # An untouched list has to SHOW that a choice is owed. It used to mark the
    # chosen one with a dot that appeared only after the click nobody made,
    # because nothing on screen looked like a control: the reader saw a name and
    # a number and never learnt that anything was expected of them.
    #
    # A box, not a circle, and the input stays a radio underneath. Only one
    # billing can take the time, so the semantics are a radio group; the box is
    # the affordance, because a lone radio circle reads as an ornament, and with
    # one billing in the list that is exactly what it looked like.
    it 'shows an empty box in front of every billing, before anything is chosen' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(30, ticket: ticket_with('Irgendwas'))

      row = panel_body[%r{<label[^>]*>.*?existingGroupOption.*?</label>}m].to_s

      expect(row).to include('type="radio"')
      # The empty box is drawn until something is picked, the filled one after.
      expect(row).to include('peer-checked:hidden')
      expect(row).to include('peer-checked:flex')
    end

    # A radio cannot be unpicked by itself: clicking the chosen one does nothing,
    # so a reader who ticked the wrong billing could only pick another or leave
    # through "eine neue Abrechnung". The controller has to be on the click for
    # that, and change alone never fires on a repeat.
    it 'wires the box so a second click can clear it again' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, organisation: organisation, name: 'aug-2026')
      end
      book(30, ticket: ticket_with('Irgendwas'))

      action = billing_option['data-action']

      expect(action).to include('click->time-session-bulk#togglePick')
      expect(action).to include('change->time-session-bulk#chooseBilling')
    end

    # The class list lives twice on purpose: the Stimulus classes API owns what
    # "closed" means, and the panel must ALSO render closed before any JavaScript
    # runs or it flashes across the page on load. Deliberate duplication, checked
    # rather than hoped for: if the two drift, the panel opens on page load or
    # never closes, and neither raises anything.
    it 'renders closed in exactly the classes the controller will toggle' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list
      declared = response.body[/data-time-session-bulk-closed-class="([^"]*)"/, 1].to_s.split
      rendered = panel[/class="([^"]*)"/m, 1].to_s.split

      expect(declared).to contain_exactly('translate-y-full', 'lg:hidden')
      expect(rendered).to include(*declared)
    end
  end

  describe 'the filter pill addresses' do
    def pill_hrefs
      get organisation_time_sessions_path(organisation, date_range: '30_days', creator_id: admin.id)
      response.body.scan(/href="([^"]*)"/).flatten
    end

    it 'never lets an href carry a scheme' do
      book(30, ticket: ticket_with('Irgendwas'))

      list_links = pill_hrefs.select { |href| href.include?('date_range=') }

      expect(list_links).to be_present
      expect(list_links).to all(start_with('/'))
    end

    # One list, one route. A project is a filter on it, and the pills keep
    # that filter the way they keep every other one.
    it 'stays on the organisation list and keeps the project filter' do
      book(30, ticket: ticket_with('Im Projekt'))

      get organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: '30_days')
      hrefs = response.body.scan(/href="([^"]*date_range=year[^"]*)"/).flatten.map { |h| CGI.unescapeHTML(h) }

      expect(hrefs).to be_present
      expect(hrefs).to all(start_with(organisation_time_sessions_path(organisation)))
      expect(hrefs).to all(include("project_id_filter=#{project.id}"))
    end

    # The point of the pills: each one changes ITS parameter and keeps the rest.
    it 'keeps the other filters while changing its own' do
      book(30, ticket: ticket_with('Irgendwas'))

      href = pill_hrefs.find { |h| h.include?('date_range=year') }

      expect(href).to include("creator_id=#{admin.id}")
      expect(href).to include('date_range=year')
    end
  end

  # The visible label came off the master checkbox on 30.08.2026. A checkbox
  # sitting above a column of checkboxes selects them all, and that is learned.
  # It is a REGRESSION, though, if the control loses its name with the text: a
  # screen reader would then read out an unnamed checkbox. Pinned in both
  # directions so "tidying up the aria-label" cannot pass as cleanup.
  describe 'the master checkbox' do
    let(:word) { I18n.t('views.organisations.time_sessions.index_table.select_all') }

    # The header line of a month: only spans inside it, so the first closing div
    # is its own.
    def month_header
      desktop[%r{<div class="flex items-baseline gap-3\.5 px-2 pb-1\.5">.*?</div>}m]
    end

    # ⚠️ This moved out to a labelled row above the table for one commit and came
    # straight back (user, 02.09.2026). The reason is the one the header
    # placement always had: it belongs in the COLUMN it commands, flush above the
    # checkboxes it toggles. What the trip settled is the label -- a checkbox at
    # the head of a column of checkboxes needs no word beside it, so the name
    # travels for screen readers only.
    it 'carries its name without printing it' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list

      expect(desktop).to include(%(aria-label="#{word}"))
      expect(Nokogiri::HTML::DocumentFragment.parse(desktop).text).not_to include(word)
    end

    it 'sits in the month header, in the same column as the row checkboxes' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list

      expect(month_header).to include('data-time-session-bulk-target="masterCheckbox"')
    end

    # One control for the whole table, so the second month must NOT grow a second
    # one: two elements with the same Stimulus target would make "select all"
    # depend on which of them the user clicked.
    it 'appears exactly once, however many months are on screen' do
      book(30, on: august, ticket: ticket_with('August'))
      book(30, on: Time.utc(2026, 7, 15, 10, 0), ticket: ticket_with('Juli'))

      get_list

      expect(desktop.scan('data-time-session-bulk-target="masterCheckbox"').size).to eq(1)
    end
  end

  # The chevron's only label is the count ("2 Zeiten"), and the glyph merely
  # ROTATES, so without this a screen reader hears a button with a number and no
  # open-or-closed state at all. The controller keeps it in step on both
  # surfaces; this pins the state the page is SERVED in, which is the one nobody
  # notices going missing because the JavaScript would still say the truth after
  # the first click.
  describe 'the row expander' do
    it 'is served closed, and says so, on both surfaces' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list

      expect(desktop).to match(/data-toggle-allowed aria-expanded="false"/)
      expect(mobile).to match(/data-toggle-allowed aria-expanded="false"/)
    end

    # Served OPEN it must say the opposite, or the very first thing a screen
    # reader is told is wrong. expand_all is the address that does that.
    it 'says open when the page is served with the rows open' do
      book(30, ticket: ticket_with('Irgendwas'))

      get_list(expand_all: '1')

      expect(desktop).to include('data-ticket-group-expanded-value="true"')
    end
  end

  # ONE slot in front of the title, holding the number OR the glyph. A "#89"
  # already says "ticket", so the ticket glyph beside it said it twice (user,
  # 30.08.2026). The sidebar renders bi-list-task too, so these look inside the
  # row and not at the whole page.
  describe 'the handle in front of the title' do
    def row_header
      desktop[/data-time-session-bulk-group.*?data-ticket-group-target="sessions"/m]
    end

    it 'gives a ticket its number and no glyph' do
      ticket = ticket_with('Ein Ticket')
      book(30, ticket: ticket)

      get_list

      expect(row_header).to include("##{ticket.number}")
      expect(row_header).not_to include(TimeSessionsHelper::SUBJECT_ICONS.fetch(:ticket))
    end

    it 'gives a meeting the glyph, because it has no number' do
      meeting = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Kickoff')
      end
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: admin,
                              duration: 30, occurred_on: august, meeting: meeting, description: 'Gespräch')
      end

      get_list

      expect(row_header).to include(TimeSessionsHelper::SUBJECT_ICONS.fetch(:meeting))
      expect(row_header).to include('Kickoff')
    end

    # The billing "Bezug" cell diverges on purpose: one cell holds both types
    # there, so both keep a glyph. Pinned so the divergence stays a decision.
    it 'keeps both glyphs in the billing subject cell' do
      ticket = ticket_with('Fuer die Abrechnung')

      cell = ApplicationController.render(
        partial: 'organisations/time_sessions/subject_cell',
        locals: { subject: ticket, link_access: {} }
      )

      expect(cell).to include(TimeSessionsHelper::SUBJECT_ICONS.fetch(:ticket))
    end
  end

  # A mark that distinguishes nothing is noise. A row showing a DOT is a row in
  # one state, so every booking under it would repeat that dot exactly; a row
  # showing a BAR is the one case where the marks below decode it.
  describe 'the marks on the bookings' do
    let(:group) { ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation) } }

    it 'leaves the bookings unmarked when the whole row is in one state' do
      ticket = ticket_with('Einheitlich')
      book(60, ticket: ticket)
      book(30, ticket: ticket)

      get_list

      # Two bookings in one state: ONE dot on the row, none on the bookings. The
      # mark says the state and nothing else since the design review.
      expect(desktop.scan(%r{border-stroke/70 h-2\.5 }).size).to eq(1)
      expect(desktop.scan(%r{border-stroke/70 h-2 })).to be_empty
    end

    # How many bookings a row holds is the chevron's job, not the mark's. Four
    # bookings still draw one dot, and the control says "4 Zeiten".
    it 'draws one mark however many bookings the row holds' do
      ticket = ticket_with('Viele')
      4.times { book(15, ticket: ticket) }

      get_list

      expect(desktop.scan(%r{border-stroke/70 h-2\.5 }).size).to eq(1)
      expect(desktop).to include('aria-label="4 Zeiten"')
    end

    it 'marks them when the row is mixed, because that is what decodes the bar' do
      ticket = ticket_with('Gemischt')
      book(60, ticket: ticket)
      book(60, ticket: ticket, group: group, billed: true)

      get_list_with_billed

      # The row draws a bar (w-10), the two bookings each draw their own dot.
      expect(desktop.scan(%r{border-stroke/70 h-2 w-6}).size).to eq(1)
      expect(desktop.scan(%r{border-stroke/70 h-2 w-2 }).size).to eq(2)
    end

    # The words stay either way: the billing a booking belongs to is named
    # nowhere else since the row's billing column came out.
    it 'keeps the state in words on the booking, with its billing' do
      book(60, ticket: ticket_with('Mit Abrechnung'), group: group)

      get_list

      expect(desktop).to include(I18n.t('views.time_sessions.billing_status.in_billing'))
      expect(desktop).to include(group.name)
    end
  end

  describe 'the duration on a booking' do
    # A sole booking carries the row's whole duration. Printing it a second time
    # directly underneath says nothing.
    def booking_text
      Nokogiri::HTML::DocumentFragment.parse(desktop)
                                      .css('[data-ticket-group-target="sessions"]')
                                      .text
    end

    it 'is left out when the row holds a single booking' do
      book(75, ticket: ticket_with('Allein'), description: 'Die einzige')

      get_list

      expect(booking_text).to include('Die einzige')
      expect(booking_text).not_to include('01:15')
    end

    it 'is printed on every booking as soon as there are two' do
      ticket = ticket_with('Zu zweit')
      book(45, ticket: ticket)
      book(30, ticket: ticket)

      get_list

      expect(booking_text).to include('00:45')
      expect(booking_text).to include('00:30')
    end
  end

  describe 'opening a row' do
    # Without something to set them apart the bookings read as siblings of the
    # rows rather than as their children. The first attempt drew a box (a left
    # rule and a tint) and looked like a stray frame; this one uses the layout:
    # the group is ONE block with a single divider at its foot, the bookings have
    # none of their own, and they are indented past the row's reference column.
    it 'closes the unfolded group off as one block, not as separate rows' do
      ticket = ticket_with('Abgesetzt')
      book(60, ticket: ticket)
      book(30, ticket: ticket)

      get_list
      block = Nokogiri::HTML::DocumentFragment.parse(desktop)
                                              .css('[data-ticket-group-target="sessions"]')
                                              .first

      expect(block['class'].split).to include('border-b')
      expect(block.css('[data-time-session-bulk-row]').map { |node| node['class'] })
        .to all(satisfy { |classes| !classes.include?('border-b') })
    end

    it 'indents the bookings past the row, so the level is visible without a box' do
      book(60, ticket: ticket_with('Eingerueckt'))

      get_list
      booking = Nokogiri::HTML::DocumentFragment.parse(desktop)
                                                .css('[data-time-session-bulk-row]')
                                                .first

      expect(booking['class']).to include('pl-14')
    end

    it 'folds the bookings away and offers a labelled control to unfold them' do
      book(60, ticket: ticket_with('Aufklappbar'))

      get_list

      block = Nokogiri::HTML::DocumentFragment.parse(desktop)
                                              .css('[data-ticket-group-target="sessions"]')
                                              .first

      expect(block).to be_present
      # The class, not the exact attribute string: the block also carries the
      # ones that set it apart from the rows around it.
      expect(block['class'].split).to include('hidden')
      # The count is the control's LABEL, not text beside it: a screen reader
      # hears it, the eye gets the chevron and the dots.
      expect(desktop).to include('aria-label="1 Zeit"')
      # ⚠️ Asked of the ROW, not of the page. The result row above the list says
      # "1 Zeit · 01:00" since the layout of 02.09.2026, and a page-wide `text`
      # check called that a label leaking into view. The claim was always about
      # this control: the count is its NAME, not text beside it.
      row = Nokogiri::HTML::DocumentFragment.parse(desktop)
                                            .css('[data-ticket-group-target="toggle"], [aria-label="1 Zeit"]')
      expect(row.text).not_to include('1 Zeit')
    end

    # Every row is openable, also a row with a single booking, because edit and
    # delete moved in there. The draft hides the control in that case.
    it 'offers it even when the row holds a single booking' do
      book(60, ticket: ticket_with('Nur eine'))

      get_list

      expect(desktop.scan('data-ticket-group-target="chevron"').size).to eq(1)
    end

    it 'unfolds every row with alle Details' do
      book(60, ticket: ticket_with('Offen'))

      get_list(expand_all: '1')

      expect(desktop).to include('data-ticket-group-expanded-value="true"')
    end
  end

  describe 'a booking inside an opened row' do
    it 'offers edit and delete on your own, unbilled booking' do
      book(60, ticket: ticket_with('Meine'), description: 'Meine Buchung')

      get_list

      expect(desktop).to include('Meine Buchung')
      expect(desktop).to include('time-session-popup#editTimeSession')
      expect(desktop).to include(t_delete_confirm)
    end

    it 'shows a lock instead once it is invoiced' do
      group = ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation) }
      book(60, ticket: ticket_with('Berechnet'), group: group, billed: true, description: 'Abgerechnete Buchung')

      get_list_with_billed

      expect(desktop).to include('bi bi-lock')
      expect(desktop).not_to include('time-session-popup#editTimeSession')
    end

    it 'offers neither on somebody else\'s booking' do
      book(60, ticket: ticket_with('Fremde'), creator: colleague, description: 'Fremde Buchung')

      get_list

      expect(desktop).to include('Fremde Buchung')
      expect(desktop).not_to include('time-session-popup#editTimeSession')
    end
  end

  describe 'the sum at the bottom' do
    it 'adds up what is on the screen' do
      book(60, ticket: ticket_with('Eins'))
      book(90, ticket: ticket_with('Zwei'))

      get_list

      expect(desktop).to include('Summe der sichtbaren Zeiten')
      expect(desktop).to include('02:30')
    end
  end

  describe 'the phone' do
    # The one thing that had to match from the start (decision of 30.08.2026):
    # the phone keeps its card layout but not its own colour language.
    # Named separately on purpose: an assertion on "some bar" passes while the
    # booking card has none, because the row card above it draws one (probed).
    # h-2 is the row bar, h-[5px] the one on a booking.
    it 'marks the row, and repeats nothing on a booking that shares its state' do
      book(60, ticket: ticket_with('Auch mobil'))

      get_list

      expect(mobile.scan(%r{class="[^"]*border-stroke/70 h-2\.5 }).size).to eq(1)
      expect(mobile.scan(%r{class="[^"]*border-stroke/70 h-2 })).to be_empty
    end

    # Since 30.08.2026 the phone shares the desktop's STRUCTURE, not only its
    # colours. It used to draw every booking of every row, always, each in its
    # own bordered box: three rows and six bookings came to 2000px of page, and
    # every change in this area had to be made twice.
    it 'folds its bookings away behind the row, like the desktop' do
      ticket = ticket_with('Mit zwei Buchungen')
      book(30, ticket: ticket, description: 'Erste Buchung')
      book(45, ticket: ticket, description: 'Zweite Buchung')

      get_list

      expect(mobile).to include('data-ticket-group-target="sessions"')
      expect(mobile).to include('data-controller="ticket-group"')
      # Rendered, but inside the folded container: the row is one tap away from
      # them, not a page of boxes.
      folded = mobile[/<div class="hidden border-b border-cream-200" data-ticket-group-target="sessions">.*?Zweite Buchung/m]
      expect(folded).to be_present
    end

    # The title is the link on both screens now. A "Zum Ticket" button used to
    # sit under every phone row, saying what the title already points at.
    it 'links the title instead of adding a button under the row' do
      ticket = ticket_with('Verlinkt')

      book(30, ticket: ticket)
      get_list
      target = organisation_project_ticket_path(organisation, project, ticket)

      expect(mobile).to include(target)
      expect(mobile).not_to include(I18n.t('views.organisations.time_sessions.index_table.go_to_ticket'))
    end

    # Same rule as the desktop: your own name on your own booking is noise. It
    # printed unconditionally on the phone, so you read yourself six times.
    it 'names the author only when it is somebody else' do
      # Distinct names on purpose: the user factory calls everybody "Test User",
      # so comparing admin.full_name with colleague.full_name would compare a
      # string with itself and pass whatever the view does.
      admin.update!(first_name: 'Ich', last_name: 'Selbst')
      colleague.update!(first_name: 'Jemand', last_name: 'Anders')
      book(30, ticket: ticket_with('Meins'), description: 'Von mir')
      book(30, ticket: ticket_with('Fremdes'), creator: colleague, description: 'Von jemand anderem')

      get_list
      # The whole mobile half carries the layout's user menu, which names the
      # signed-in person legitimately. Only the booking lines are the question.
      lines = mobile.scan(/<div class="flex items-start gap-3 py-2 pl-7".*?(?=<div class="flex items-start gap-3 py-2 pl-7"|\z)/m).join

      expect(lines).to include('Jemand Anders')
      expect(lines).not_to include('Ich Selbst')
    end

    it 'says the state in the same words and heads the month' do
      book(60, ticket: ticket_with('Auch mobil'))

      get_list

      expect(mobile).to include(I18n.t('views.time_sessions.billing_status.without_billing'))
      expect(mobile).to include('August 2026')
    end
  end

  describe 'the checkboxes' do
    # A can_view_all user without the admin role SEES everybody's time but may
    # only assign their own. Before one rule owned this, the row offered a
    # checkbox ("something here is unbilled") that selected nothing, and the
    # server refused the whole bulk assignment.
    let(:viewer) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: viewer, organisation: organisation, active: true)
        create(:time_session_permission, user: viewer, project: project, can_view_all: true)
      end
      sign_in viewer
    end

    it 'offers none on a row that is entirely somebody else\'s' do
      book(60, ticket: ticket_with('Nur fremd'), creator: colleague)

      get_list

      expect(desktop).to include('Nur fremd')
      expect(desktop).not_to include('data-time-session-bulk-target="groupCheckbox"')
      expect(desktop).not_to include('data-time-session-bulk-target="checkbox"')
    end

    it 'offers both on your own booking' do
      book(60, ticket: ticket_with('Meins'), creator: viewer)

      get_list

      expect(desktop).to include('data-time-session-bulk-target="groupCheckbox"')
      expect(desktop).to include('data-time-session-bulk-target="checkbox"')
    end
  end

  describe 'the selection markers' do
    # The bulk controller looks for markers of OUR own. Pinned here because a
    # missing one is silent: the checkbox simply selects nothing.
    it 'marks the row and the booking, on both layouts' do
      book(60, ticket: ticket_with('Markiert'))

      get_list

      expect(desktop.scan('data-time-session-bulk-group').size).to eq(1)
      expect(desktop.scan('data-time-session-bulk-row').size).to eq(1)
      expect(mobile.scan('data-time-session-bulk-group').size).to eq(1)
      expect(mobile.scan('data-time-session-bulk-row').size).to eq(1)
    end

    # This is what was broken before: on the phone the bookings were a SIBLING of
    # the header, so the row checkbox found no bookings at all. Parsed rather
    # than matched, because containment is the claim and a regex over the body
    # only sees the ORDER of two strings (probed: it passes either way).
    it 'keeps the phone bookings INSIDE the marked row' do
      book(60, ticket: ticket_with('Innen'))

      get_list

      groups = Nokogiri::HTML::DocumentFragment.parse(mobile).css('[data-time-session-bulk-group]')

      expect(groups.size).to eq(1)
      expect(groups.first.css('[data-time-session-bulk-row]').size).to eq(1)
    end
  end

  describe 'the "nur meine Zeiten" switch' do
    # A filter that cannot change the result is not a filter. Someone who may see
    # only their own hours would be filtering the list down to itself.
    let(:pill) { I18n.t('views.organisations.time_sessions.index.filter_only_mine', default: 'Nur meine Zeiten') }
    let(:viewer) { create(:user) }

    def sign_in_viewer_with(**flags)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: viewer, organisation: organisation, active: true)
        create(:time_session_permission, user: viewer, project: project, **flags)
      end
      sign_in viewer
    end

    it 'is there for an account admin' do
      book(60, ticket: ticket_with('Egal'))

      get_list

      expect(response.body).to include(pill)
    end

    it 'is there for someone who may see everybody\'s hours' do
      sign_in_viewer_with(can_view_all: true)
      book(60, ticket: ticket_with('Egal'))

      get_list

      expect(response.body).to include(pill)
    end

    it 'is gone for someone who may see only their own' do
      sign_in_viewer_with(can_view_own: true, can_view_all: false)
      book(60, ticket: ticket_with('Egal'), creator: viewer)

      get_list

      expect(response.body).not_to include(pill)
    end
  end

  describe 'remembering an open row' do
    # The bulk assignment answers with a redirect, so without a key every row the
    # reader had opened to decide what to select folds away again.
    it 'gives each row a key, and only as UI state' do
      book(60, ticket: ticket_with('Gemerkt'))

      get_list
      keys = Nokogiri::HTML::DocumentFragment.parse(desktop)
                                             .css('[data-ticket-group-key-value]')
                                             .map { |node| node['data-ticket-group-key-value'] }

      expect(keys.size).to eq(1)
      # project, ticket, meeting, month -- a position on a screen, not a record.
      expect(keys.first.split('|', -1).size).to eq(4)
    end
  end

  describe 'the filter pills above the list' do
    # They are rendered ONCE, with the page, and the filters below them update a
    # Turbo frame. So every pill kept pointing at the query the page was opened
    # with: coming from a ticket, setting the ticket filter back to "all" and then
    # clicking "alle Details" put the ticket filter back.
    #
    # Each pill now declares only what it CHANGES; query_toggle_controller keeps
    # the rest from the address the browser is actually on.
    it 'declares what it changes instead of carrying the whole page-load query' do
      ticket = ticket_with('Vom Ticket gekommen')
      book(60, ticket: ticket)

      get_list(ticket_id: ticket.id)
      pills = Nokogiri::HTML::DocumentFragment.parse(response.body).css('[data-query-toggle-owns]')

      expect(pills).not_to be_empty
      details = pills.find { |node| node['data-query-toggle-owns'].include?('expand_all') }
      expect(JSON.parse(details['data-query-toggle-owns'])).to eq([%w[expand_all 1]])
      # It owns expand_all and nothing else, so it cannot revive ticket_id.
      expect(details['data-query-toggle-owns']).not_to include('ticket_id')
    end

    it 'turns the flag off again by owning it with an empty value' do
      book(60, ticket: ticket_with('Egal'))

      get_list(expand_all: '1')
      details = Nokogiri::HTML::DocumentFragment.parse(response.body)
                                                .css('[data-query-toggle-owns]')
                                                .find { |node| node['data-query-toggle-owns'].include?('expand_all') }

      expect(JSON.parse(details['data-query-toggle-owns'])).to eq([['expand_all', '']])
    end

    # Without this the address never follows the frame, and there is nothing
    # live for the pills to rebuild from.
    it 'lets the list frame advance the address' do
      book(60, ticket: ticket_with('Egal'))

      get_list

      expect(response.body).to include('data-turbo-action="advance"')
    end
  end

  def t_delete_confirm
    I18n.t('views.confirm.delete_time_session')
  end
end

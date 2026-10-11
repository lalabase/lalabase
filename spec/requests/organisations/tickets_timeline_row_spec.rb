# frozen_string_literal: true

require 'rails_helper'

# Guard: what one row of the ticket timeline shows.
#
# Since the 05.09.2026 mockup: mono is for VALUES, proportional for speech. A
# comment carries its age ("vor 4 Minuten", proportional, exact moment in the
# tooltip); a change row carries the exact clock time ("16:07", mono, right
# aligned); the day header carries the numeric date - and no row ever repeats
# it. All kinds of row start their text on the same edge, and the ticket's
# birth is a change row like any other.
#
# The drift this pins (reported 05.09.2026 on a screenshot): every row printed
# the full "22.04.2026 16:00" under a header already reading "22. April 2026",
# and the three item kinds each formatted their own timestamp - the post and
# the activity through display_time_ago with different area preferences, the
# time session with a hardcoded strftime. So one list showed relative and
# absolute times side by side under one exact date header.
#
# This is a REQUEST spec on purpose: the rule spans a partial (the day header)
# and three components, and only the rendered page proves that the header and
# the rows agree. A component spec can pin one half and stay green while the
# other half repeats the date.
# Anything that reads as a date rather than a clock time. The year alone is the
# honest test: "22.04.2026", "22. April 2026" and "2026-04-22" all carry one,
# and no clock time does.
TIMELINE_DATE_LIKE = /\b20\d{2}\b/

RSpec.describe 'Ticket timeline row', type: :request do
  # A day whose header is a written date, safely in the past so it is never
  # "Heute"/"Gestern" - those two are asserted separately below.
  let(:past_day) { Date.new(2026, 4, 22) }
  let(:past_moment) { Time.zone.local(2026, 4, 22, 16, 0) }
  let(:later_moment) { Time.zone.local(2026, 4, 22, 17, 15) }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Guido', last_name: 'Boyke') }

  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))

    post = create(:post, ticket: ticket, organisation: organisation, user: user,
                         content: 'Habe ich gemacht.')
    # Both stamps: an untouched comment must not read as edited (the edited
    # marker compares the two).
    post.update_columns(created_at: past_moment, updated_at: past_moment)

    activity = create(:activity, :status_changed, trackable: ticket, actor: user,
                                                  organisation: organisation)
    activity.update_column(:created_at, later_moment)

    # The timeline only loads time sessions the viewer may see
    # (TicketTimelineService#load_time_sessions); without this the row is
    # absent and the "no time" assertion below would pass on nothing.
    create(:time_session_permission, user: user, project: project, can_view_all: true)
    create(:time_session, project: project, ticket: ticket, organisation: organisation,
                          creator: user, occurred_on: past_day, duration: 90)

    sign_in user
    get timeline_organisation_project_ticket_path(organisation, project, ticket)
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:document) { Nokogiri::HTML5.fragment(response.body) }
  let(:day_header) { document.css('[data-timeline-filter-target="dayGroup"] > div').first }
  # The comment component's own root, not the filter wrapper around it: the
  # component is what carries the reveal marker, because posts#create renders
  # it on its own into the turbo frame.
  let(:post_row) { document.css('.post-card').first }
  let(:activity_row) { document.css('[data-timeline-filter-target="activity"]').first }
  let(:time_session_row) { document.css('.time-session-card').first }

  it 'renders the day header as the numeric date (the matcher can match)' do
    # Deliberately first: every "no date" assertion below is worthless unless
    # TIMELINE_DATE_LIKE demonstrably matches the one place a date belongs.
    # Numeric on purpose: dates are values (user mockup 05.09.2026).
    expect(day_header.text).to match(TIMELINE_DATE_LIKE)
    expect(day_header.text.strip).to eq(I18n.l(past_day, format: :default))
  end

  it 'gives the comment row an age and no date' do
    expect(post_row.text).not_to match(TIMELINE_DATE_LIKE)
    expect(post_row.at_css('time').text.strip)
      .to eq(I18n.t('views.common.relative_time_ago', time: ActionController::Base.helpers.time_ago_in_words(past_moment)))
  end

  it 'keeps the exact moment reachable on the comment row as a hover title' do
    # The precision is not lost, it moves out of the way.
    expect(post_row.at_css('time')['title']).to eq(I18n.l(past_moment, format: :long))
    expect(post_row.at_css('time')['datetime']).to eq(past_moment.iso8601)
  end

  it 'gives the activity row the exact clock time and no date' do
    expect(activity_row.text).not_to match(TIMELINE_DATE_LIKE)
    expect(activity_row.at_css('time').text.strip).to eq('17:15')
    # The full moment stays reachable as the hover title.
    expect(activity_row.at_css('time')['title']).to eq(I18n.l(later_moment, format: :long))
  end

  # Times are ALWAYS visible since the 05.09.2026 mockup rounds, and mono is
  # for values only: the comment's age is speech (proportional), the change
  # row's clock time is a value (mono, right-aligned).
  describe 'the always-visible times' do
    it 'shows the comment age proportional next to the head, outside any reveal' do
      expect(post_row.at_css('[data-hover-reveal-target="actions"]')).to be_nil
      time_span = post_row.at_css('time')
      expect(time_span).to be_present
      expect(time_span.parent[:class]).not_to include('font-mono')
    end

    it 'right-aligns the activity time in mono' do
      expect(activity_row.at_css('[data-hover-reveal-target="actions"]')).to be_nil
      time_span = activity_row.at_css('time')
      expect(time_span).to be_present
      expect(time_span.parent[:class]).to include('font-mono', 'shrink-0')
    end
  end

  # The ticket's birth is a change row like any other (user mockup
  # 05.09.2026) - but ALWAYS visible: it replaced the footer below the
  # timeline, and a footer never hid behind the "nur Kommentare" filter
  # either.
  describe 'the creation row' do
    let(:creation_row) do
      # The innermost quiet row, not an ancestor that merely contains it.
      document.css('div').find do |d|
        (d['class'] || '').include?('pl-[38px]') && d.text.include?('Ticket angelegt')
      end
    end

    it 'names the creator in the viewer spelling with the clock time on the right' do
      expect(creation_row).to be_present
      expect(creation_row.text).to include(I18n.t('views.organisations.tickets.timeline.created_line', name: 'Guido Boyke'))
      time_span = creation_row.at_css('time')
      expect(time_span.text.strip).to match(/\A\d{2}:\d{2}\z/)
      expect(time_span.parent[:class]).to include('font-mono', 'shrink-0')
    end

    it 'is not a filterable activity row (it stays when only comments show)' do
      wrapper = document.css('[data-timeline-filter-target]').find { |d| d.text.include?('Ticket angelegt') && d['data-timeline-filter-target'] != 'dayGroup' }
      expect(wrapper).to be_nil
    end

    it 'no longer renders the old closing footer' do
      expect(response.body).not_to include('angelegt von')
    end
  end

  it 'gives the time session row no time at all (it knows a day, not a moment)' do
    # occurred_on is a date; timestamp_for turns it into 00:00 so it can sort.
    # Printing that would claim every booking happened at midnight.
    expect(time_session_row.text).not_to match(TIMELINE_DATE_LIKE)
    expect(time_session_row.at_css('time')).to be_nil
    expect(time_session_row.text).not_to include('00:00')
  end

  # A time entry ranks between comment and change (designer round
  # 05.09.2026): the 26px column names the KIND with a frameless clock, the
  # duration leads as the number one reads, and the person sits quietly below
  # as a data field, not an author.
  describe 'the time entry rank' do
    it 'leads with the bare duration in mono, no leading zero and no unit' do
      duration = time_session_row.at_css('.font-mono')
      expect(duration.text.strip).to eq('1:30')
      expect(time_session_row.text).not_to include('01:30')
    end

    it 'marks the kind with a frameless clock in the 26px column' do
      icon_cell = time_session_row.at_css('span[aria-hidden="true"]')
      expect(icon_cell[:class]).to include('w-[26px]')
      expect(icon_cell.at_css('i.bi-clock')).to be_present
    end

    it 'keeps the word for screen readers only and names the person below' do
      # The clock icon names the kind, so the word would say it twice.
      label = time_session_row.css('span').find { |s| s.text.strip == I18n.t('views.organisations.tickets.timeline.time_entry_label') }
      expect(label[:class]).to include('sr-only')
      expect(time_session_row.text).to include('Guido Boyke')
    end
  end

  # The screenshot that started this (05.09.2026): a viewer on 'circle' saw an
  # avatar and a timestamp and NO name, so the loudest thing in the row was the
  # least important one and the author was hidden behind a hover title. The
  # circle mode is right where a row has another anchor (a ticket list, a
  # kanban card); in a conversation the author IS the anchor.
  describe 'the author mark' do
    let(:mark) { post_row.at_css('[title="Guido Boyke"]') }

    it 'carries the initials and the full name as its title' do
      expect(mark.text.strip).to eq('GB')
    end

    it 'stands beside the author name in the viewer spelling (Slack model, 05.09.2026)' do
      # Revised the same day: the mark-only row hid the author behind a hover
      # title. Slack was the user's reference - picture AND bold name.
      expect(post_row.text).to include('Guido Boyke')
    end

    it 'is the ONE app-wide chip (5px corner, small size), not a special shape' do
      # Unified on 05.09.2026 (user report: circles here, squares there). The
      # corner itself is pinned once, in avatar_component_spec.
      expect(mark[:class]).to include('neo-user-avatar', 'w-[26px]', 'h-[26px]')
      expect(mark[:class]).not_to include('rounded-full')
    end

    context 'when the viewer changed the name display setting' do
      before do
        user.update!(preferences: user.preferences.merge('name_display' => 'first_last_initial'))
        get timeline_organisation_project_ticket_path(organisation, project, ticket)
      end

      # The setting governs the SPELLING of the name beside the mark; the
      # mark itself is there either way (Slack model, 05.09.2026).
      it 'keeps the mark and respells the name' do
        expect(post_row.at_css('[title="Guido Boyke"]').text.strip).to eq('GB')
        expect(post_row.text).to include('Guido B.')
        expect(post_row.text).not_to include('Guido Boyke')
      end
    end
  end

  # If the quiet rows start further left or further right than the comments,
  # the timeline falls apart into rows of equal loudness again. The number is
  # the chip's width plus its gap: 26 + 12.
  it 'starts every kind of text on the same edge' do
    expect(post_row.at_css('[title="Guido Boyke"]')[:class]).to include('w-[26px]')
    expect(post_row.at_css('.flex.gap-3')).to be_present

    # The change row indents past an EMPTY kind column; the time entry fills
    # the same column with its clock icon - both land on the comment's edge.
    expect(activity_row.to_html).to include('pl-[38px]')
    expect(time_session_row.at_css('span[aria-hidden="true"]')[:class]).to include('w-[26px]', 'shrink-0')
  end

  # The lime edge was the ONLY ownership signal while the name was gone. With
  # the name back it answers the same question a second time, and the reader
  # never asked it: they know what they wrote.
  it 'marks own comments with no coloured edge any more' do
    expect(post_row.to_html).not_to include('border-l-lime-400')
    # ... and nothing is left holding its place either.
    expect(post_row.to_html).not_to include('-ml-4')
  end

  # The change row speaks field-first since the designer round 05.09.2026:
  # "Status Offen → Erledigt" instead of "Status von 'Open' auf 'Closed'
  # (Guido Boyke)". Display values, never raw keys in quotes; the ticket
  # title never (it stands in the head); the actor only when the person
  # switches from the entry above.
  describe 'the change row grammar' do
    it 'speaks field first with an arrow and no sentence' do
      expect(activity_row.text).to include('Status')
      expect(activity_row.text).to include('→')
      expect(activity_row.text).not_to include("von 'Open'")
      expect(activity_row.text).not_to include("auf 'Closed'")
      expect(activity_row.text).not_to include(ticket.title)
    end

    it 'stays silent about the actor while the person does not switch' do
      # The comment directly above this change is by the same person.
      expect(activity_row.text).not_to include('Guido Boyke')
    end

    context 'when the project defines display values' do
      before do
        create(:ticket_attribute_definition, :select, project: project, name: 'status',
                                                      labels: { 'de' => 'Status', 'en' => 'Status' },
                                                      options: { 'allowed_values' => [
                                                        { 'value' => 'Open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                                        { 'value' => 'Closed', 'labels' => { 'de' => 'Erledigt', 'en' => 'Closed' } }
                                                      ] })
        get timeline_organisation_project_ticket_path(organisation, project, ticket)
      end

      it 'renders them instead of the raw values' do
        expect(activity_row.text).to include('Offen', 'Erledigt')
        expect(activity_row.text).not_to include('Open', 'Closed')
      end
    end

    context 'when the person switches' do
      before do
        # The request above cleared the tenant thread state.
        ActsAsTenant.current_tenant = organisation
        colleague = create(:user, first_name: 'Anna', last_name: 'Berg')
        switch = create(:activity, :status_changed, trackable: ticket, actor: colleague,
                                                    organisation: organisation)
        switch.update_column(:created_at, later_moment + 5.minutes)
        get timeline_organisation_project_ticket_path(organisation, project, ticket)
      end

      it 'names the actor on the switching row only' do
        rows = document.css('[data-timeline-filter-target="activity"]')
        expect(rows.first.text).not_to include('Guido Boyke')
        expect(rows.last.text).to include('Anna Berg')
      end
    end
  end

  # A click cascade collapses into ONE row (designer round 05.09.2026): the
  # net result with the time span, the single steps in a disclosure.
  describe 'the collapsed run' do
    let(:run_row) do
      document.css('[data-timeline-filter-target="activity"]').find do |d|
        d.text.include?('Benachrichtigte geändert')
      end
    end

    before do
      # The request above cleared the tenant thread state.
      ActsAsTenant.current_tenant = organisation
      anna = create(:user, first_name: 'Anna', last_name: 'Berg')
      carla = create(:user, first_name: 'Carla', last_name: 'Roth')
      [[anna, Time.zone.local(2026, 4, 22, 10, 28)],
       [carla, Time.zone.local(2026, 4, 22, 10, 30)]].each do |subscriber, at|
        step = create(:activity, action: 'subscriber_added', key: 'ticket.subscriber_added',
                                 trackable: ticket, actor: user, organisation: organisation,
                                 secondary: subscriber, parameters: { 'display_name' => ticket.title })
        step.update_column(:created_at, at)
      end
      get timeline_organisation_project_ticket_path(organisation, project, ticket)
    end

    it 'shows the net result with the time span on the right' do
      expect(run_row).to be_present
      expect(run_row.text).to include('Benachrichtigte geändert: Anna Berg, Carla Roth')
      expect(run_row.at_css('time').text.strip).to eq('10:28–10:30')
    end

    it 'keeps the single steps in a disclosure, each with its own clock' do
      disclosure = run_row.at_css('details')
      expect(disclosure.at_css('summary').text.strip)
        .to eq(I18n.t('views.organisations.tickets.timeline.steps', count: 2))
      expect(disclosure.text).to include(
        I18n.t('views.organisations.tickets.timeline.subscriber_added_line', name: 'Anna Berg')
      )
      expect(disclosure.css('time').map { |t| t.text.strip }).to include('10:28', '10:30')
    end
  end

  # "Bearbeitet ist keine Zeile" (designer round 05.09.2026): an edit is a
  # property of the comment - a quiet marker in its head, the exact moment in
  # the tooltip, no row of its own.
  describe 'the edited comment' do
    let(:edit_moment) { past_moment + 2.hours }

    it 'shows no marker for an untouched comment' do
      expect(post_row.text).not_to include(I18n.t('views.organisations.tickets.timeline.edited'))
    end

    context 'when the comment was edited' do
      before do
        # The request above cleared the tenant thread state.
        ActsAsTenant.current_tenant = organisation
        ticket.posts.first.update_column(:updated_at, edit_moment)
        get timeline_organisation_project_ticket_path(organisation, project, ticket)
      end

      it 'carries the quiet marker with the moment as its tooltip' do
        marker = post_row.css('span[title]').find { |s| s.text.include?(I18n.t('views.organisations.tickets.timeline.edited')) }
        expect(marker).to be_present
        expect(marker['title']).to eq(I18n.l(edit_moment, format: :long))
      end
    end
  end

  context 'when the entries are from today and yesterday' do
    let(:past_day) { Date.current }
    let(:past_moment) { Time.current.change(hour: 9, min: 5) }
    let(:later_moment) { 1.day.ago.change(hour: 9, min: 5) }

    it 'stays numeric even for the two days a reader thinks of by name (mockup 05.09.2026)' do
      # The first child of each day group is its header.
      headers = document.css('[data-timeline-filter-target="dayGroup"]').map { |g| g.element_children.first.text.strip }

      expect(headers).to include(I18n.l(Date.current, format: :default))
      expect(headers).to include(I18n.l(Date.current - 1, format: :default))
      expect(headers).to all(match(TIMELINE_DATE_LIKE))
    end
  end
end

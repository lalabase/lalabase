# frozen_string_literal: true

# Time list: how a subject presents itself (icon, reference, title, link, and the
# permission area that gates it), the one rule for "may this person move this
# booking into a billing", the one word for a billing state, and the select
# collections of the forms. Further down, each under its own `# ---` header:
# the filter address and the owns declarations the pills carry (query_toggle),
# the empty state's removable filters (S3) and what a billing choice takes with
# it (S4).
#
# The pill classes, the status dots and the three-stage status helper that used
# to live here are gone with the redesign (S4/T9): a state is now a bar
# (NeoTimeShareBarComponent, the one owner of the three time-* tokens) plus a
# word, and the per-session classification belongs to
# TimeSession.billing_bucket_for.
module TimeSessionsHelper
  # How one time-list subject renders. Immutable value object so callers can't
  # accidentally mutate shared presentation state.
  # `reference` is the short handle a table column can right-align ("#89"), nil
  # for a subject that has none, and `title` is the bare title beside it. `label`
  # stays the full one-line form the older surfaces render, so nobody has to take
  # a regex to it to get the two halves back.
  #
  # nav_label came out on 31.08.2026 with its last reader: the phone's row used
  # to carry a "Zum Ticket" button under it, and the title is the link on both
  # screens now. It had no consumer left but its own spec.
  SubjectPresentation = Data.define(:icon, :reference, :title, :label, :path, :read_area) do
    # Does the GLYPH do the identifying, or the number? One slot in front of the
    # title, filled by one or the other, so the column stays a column whatever
    # the subject is (user, 30.08.2026): a "#89" already says "ticket", and a
    # ticket glyph beside it only says it twice. A meeting has no number, so
    # there the glyph IS the handle.
    #
    # The billing "Bezug" cell deliberately does NOT ask this and keeps both
    # glyphs -- see the note in _subject_cell.html.erb. There both subject types
    # share ONE cell, and a glyph on only one of them reads as a flag rather
    # than as a type.
    def glyph_as_handle?
      reference.nil?
    end
  end

  # Subject glyphs — deliberately the SAME icons the project sidebar uses for those
  # areas, so the glyph a user learned in the navigation is the glyph they meet
  # again in a billing "Bezug" cell. Duplicated rather than read from
  # NeoSidebarProjectItemComponent::NAV_ITEMS to keep this helper free of a
  # load-time dependency on a component; the pair is held together by
  # spec/helpers/subject_icons_match_navigation_guard_spec.rb, which fails if the
  # sidebar ever moves on without this list.
  SUBJECT_ICONS = { ticket: 'bi-list-task', meeting: 'bi-chat-quote' }.freeze

  # The subject of a time session is a Ticket OR a Meeting (Gespräche Slice 2) — or
  # nil for a subject-less session. This is the SINGLE place that knows how each
  # subject type presents itself: its icon, its label, the link target, the
  # permission area that gates the link, and the "go to …" label. Three call sites
  # render their own, genuinely different markup but all read these parts here: the
  # table row (_aggregate_row), the mobile row (_mobile_ticket_group) and the
  # billing "Bezug" cell (_subject_cell, used by all three billing views) — so a
  # third subject type is added by extending THIS method, never by editing partials
  # in lockstep. That lockstep is exactly how the meeting glyph would end up right
  # on desktop and wrong on mobile. Returns nil for the no-subject row; the caller
  # then renders its own "Ohne Bezug" placeholder.
  def time_session_subject_presentation(subject)
    # Pure function of the subject (org derived from subject.project, not the
    # ambient current_organisation) so it is trivially unit-testable and can't
    # depend on request state. In the time list a subject always belongs to the
    # current tenant, so subject.project.organisation IS current_organisation.
    case subject
    when Ticket
      project = subject.project
      SubjectPresentation.new(
        # Tickets used to render glyph-less here (design-review D8: the #number
        # prefix identifies them). That held while this presentation only fed the
        # time list, where a ticket is the norm and the meeting glyph marks the
        # exception. It stops holding in the billing "Bezug" column, where both
        # types share one cell: a glyph on only one of them reads as a flag, not
        # as a type. Symmetric glyphs, both taken from the sidebar.
        icon: SUBJECT_ICONS.fetch(:ticket),
        reference: "##{subject.number}",
        title: subject.title,
        label: "##{subject.number} / #{subject.title}",
        path: organisation_project_ticket_path(project.organisation, project, subject),
        read_area: :tickets
      )
    when Meeting
      project = subject.project
      SubjectPresentation.new(
        icon: SUBJECT_ICONS.fetch(:meeting), # design-review D8: the meeting glyph, everywhere
        reference: nil,
        title: subject.title,
        label: subject.title,
        path: organisation_project_meetings_path(project.organisation, project, meeting_id: subject.id),
        read_area: :meetings
      )
    end
  end

  # The page-load fallback address of a filter or display pill: the list address
  # the reader is on, with a few query keys changed. A blank value drops its key.
  # The address itself is TimeListHelper#time_list_path.
  #
  # ONE builder for what were five hand-rolled "#{request.path}?#{...to_query}"
  # strings across two partials. That shape puts a visitor-supplied query string
  # next to a path inside one interpolated string, which is what Brakeman's
  # LinkToHref check flags. It was frozen unchecked in the 27.08.2026 baseline
  # and named in CLAUDE.md as one of the five high-confidence entries; touching
  # the file is the moment to clear it rather than re-freeze it.
  #
  # The path is the named route of the one list, and to_query escapes what
  # follows it, so nothing a visitor sends can reach the scheme position of an
  # href.
  #
  # The href is only the no-JavaScript fallback. On click,
  # query_toggle_controller.js rebuilds it from the LIVE address, because the
  # pills are rendered once with the page and go stale the moment a filter
  # changes (lib/query_toggle.js). Each pill declares what it owns.
  def time_list_filter_url(changes = {})
    # The path comes from a NAMED ROUTE, never from the request. url_for with a
    # hash is not available in this app's views (ActionView::RoutingUrlFor is not
    # in the view's ancestors, which is why the whole codebase hand-builds these),
    # so the route helper is what routes here. The tenant comes from the current
    # organisation, so no query a visitor appends can aim somebody's own filter
    # pill at another tenant; a project is just another key of the query.
    # The query arithmetic itself is FilterUrlHelper#filter_url_for since P2 of
    # the billings redesign, which builds the same shape against its own route.
    filter_url_for(time_list_path(current_organisation), changes)
  end

  # The one-line name a booking answers to where its row is not around it: in the
  # assignment panel's list of what is about to be taken over. Its own
  # description first, because that is what distinguishes two bookings on the
  # same ticket, then the subject, then the placeholder the list already uses for
  # a booking without one.
  #
  # Lives here and not in either checkbox partial: the desktop line and the phone
  # card both carry it, and a booking that reads one way on one screen and
  # another way on the other is the bug this file keeps preventing.
  def time_session_short_label(time_session)
    return time_session.description if time_session.description.present?

    # No description: the subject alone is NOT enough, because two bookings on
    # one ticket would then read identically in a list whose whole point is
    # telling the reader exactly what is about to be taken over. The date is what
    # separates them, and it is what the booking line shows beside them anyway.
    subject = time_session_subject_presentation(time_session.ticket || time_session.meeting)&.title
    date = l(time_session.occurred_on.to_date, format: :short)
    "#{date} #{subject || t('views.time_sessions.billing_status.without_subject')}"
  end

  # The tick a reader puts on a booking, a row, or all of them. ONE string,
  # because it sat byte-identical in five partials and drifted from the panel
  # beside it: the list ticked in cobalt while the panel ticked in ink, so one
  # screen showed two kinds of tick for one kind of act (user, 31.08.2026).
  #
  # The panel's own box is drawn by hand from two spans, because a radio styled
  # as a box needs peer-checked siblings; it uses the same colours on purpose.
  # F11, the multi-select box. The ring is focus-VISIBLE, not focus: a click
  # gives a checkbox the focus too, and a black ring around the box somebody
  # just clicked reads as an error, not as a position. Keyboard readers still
  # get it, which is who it was ever for.
  TIME_LIST_CHECKBOX_CLASSES =
    'h-4 w-4 rounded border-2 border-cream-400 text-ink focus:outline-none ' \
    'focus-visible:ring-2 focus-visible:ring-ink focus-visible:ring-offset-0'

  # The route a booking answers under: the project-scoped one on a project's
  # list, the organisation-wide one on "Zeiten". One owner for a choice
  # that two desktop and two mobile call sites used to make by hand each.
  # Extra query params ride along (the delete button declares context: so destroy
  # knows it is answering the list and repaints it whole).
  def time_session_list_path(time_session, project:, **query)
    if project.present?
      organisation_project_time_session_path(current_organisation, time_session.project, time_session, **query)
    else
      organisation_time_session_path(current_organisation, time_session, **query)
    end
  end

  # May THIS person move THIS booking into a billing? ONE rule, asked by the row,
  # by the booking under it and by the mobile card. Before it existed the row
  # asked "is any of them unbilled" while the booking also asked "may I assign
  # other people's", so a can_view_all user without admin got a checkbox that
  # selected nothing and a bulk assignment the server then refused as a whole.
  def time_session_selectable?(time_session, can_bulk_assign_others: false)
    !time_session.billed? && (can_bulk_assign_others || time_session.creator == current_user)
  end

  # --- The filter pills of the time list ------------------------------------
  #
  # --- What a frame answer has to bring with it -----------------------------
  #
  # The regions of the page that sit OUTSIDE time_sessions_list_frame and whose
  # content is a reading of the very query that frame answers. Turbo swaps the
  # frame and leaves everything around it alone, so each of these would keep the
  # figure the page was opened with: three hours standing beside a list saying
  # nothing matched.
  #
  # ⚠️ A LIST, because it was a hand-written turbo_stream.replace per region and
  # the count of regions kept growing. Two were wired and documented at length;
  # the two added with the result row were not, and the same search that the
  # first two exist for left them stale. A rule enforced once per consumer is a
  # rule that will be missed by the next consumer.
  #
  # Every partial here takes NO locals and reads its own ivars, so this can stay
  # data. _index_table renders them all, inside the frame -- an element placed
  # after </turbo-frame> is discarded by Turbo, present in the body and never
  # applied.
  FRAME_DEPENDENT_REGIONS = %w[
    status_pills
    filter_reset
    result_summary
    search_hits
  ].freeze

  # The chip the EMPTY state offers a filter for removal on ("Zeitraum: 01.09.
  # bis 30.09. ✕"). One shape, one state, one caller pair (_empty_filtered).
  #
  # ⚠️ This was PILL_BASE plus a three-state PILL_STATES map, shared with the
  # status row and the choice surfaces. Both of those grew their own vocabularies
  # when the filter panel was rebuilt (CHOICE_STATES and STATUS_BOX below), and
  # the map was left behind with two of its three entries unreachable, beside a
  # figure map (PILL_FIGURE_TONES) nothing read at all. A shared definition with
  # only one consumer left is not shared; it is a second vocabulary waiting to
  # disagree with the first.
  #
  # cream-600 on cream-50 is 5.23:1. cream-500 measured 3.15:1 and failed AA for
  # the 12px text this sits on.
  REMOVAL_CHIP_CLASSES = 'inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium ' \
                         'border border-cream-300 bg-cream-50 text-cream-700 ' \
                         'hover:bg-cream-100 hover:border-cream-400 transition-colors'

  # The CHOICE surfaces of the filter line (Handout §3.2).
  #
  # ⚠️ Their own map, NOT PILL_STATES. The two rows say different things and say
  # them differently: a status pill is a SWITCH whose fill means on, a choice
  # surface asks "which one".
  #
  # ⚠️ The grounds were inverted once before, on 02.09.2026, when the filter
  # PANEL went light: the narrowing pill took a white ground with a firm dark
  # ring, the resting one the tinted fill. That reading is now turned back, and
  # not as a matter of taste - the filter zone became a white STRIPE
  # (surface-raised, see the wrapper in time_sessions/index.html.erb), and on
  # white the old map inverts itself: a white "narrowing" pill dissolves into
  # the ground while the pills that narrow NOTHING become the loudest things in
  # the zone. Exactly the signal the row exists to carry, lost the other way
  # round.
  #
  # So: tint means SELECTED, here and nowhere else in the zone. A narrowing pill
  # wears the tinted fill and a little more weight; a resting one wears no fill
  # at all and lets its chevron say that it opens. The ink outline is not used
  # here - that one belongs to the main action.
  #
  # ⚠️ "alle Projekte", "alle Bezüge", "alle Abrechnungen" and the period "alles"
  # are NOT narrowing and wear no fill. That is the same question
  # time_filter_active_count asks, one layer up.
  CHOICE_BASE = 'inline-flex items-center gap-2 px-[11px] py-1.5 rounded-lg ' \
                'text-[13px] transition-colors ' \
                'focus-visible:outline focus-visible:outline-2 focus-visible:outline-ink focus-visible:-outline-offset-2'

  CHOICE_STATES = {
    # not narrowing: no fill on the stripe, the chevron carries "openable"
    open: 'text-cream-800 hover:bg-cream-100',
    # narrowing: the tinted fill, medium weight. Tint = selected.
    active: 'bg-cream-200 text-cream-900 font-medium',
    # cannot be chosen at all: the palest fill and the quietest word
    empty: 'bg-cream-100 text-cream-500 cursor-default'
  }.freeze

  def time_filter_choice_pill_classes(state)
    "#{CHOICE_BASE} #{CHOICE_STATES.fetch(state)}"
  end

  # The status row's checkbox and its figure (Handout §3.3).
  #
  # ⚠️ A real square, not a pill and not an icon glyph. The three states are a
  # SET the reader adds to and takes from, and a checkbox is the one control
  # everyone already reads that way; as filled pills they looked like the four
  # choices above them, which are a different question entirely.
  #
  # A bucket with nothing in it keeps its box (the set is always three) but goes
  # quiet: it is not a thing to click, it is a thing to know is empty.
  STATUS_BOX_BASE = 'inline-flex items-center justify-center w-[15px] h-[15px] rounded flex-shrink-0 border'
  STATUS_BOX = {
    on: 'border-ink bg-ink text-cream-50',
    off: 'border-cream-500 bg-cream-50',
    empty: 'border-cream-400 bg-cream-50'
  }.freeze

  # The row's link wrapper: one shape, used by all three states and by
  # "nur meine Zeiten". It sat as a byte-identical literal at two call sites and
  # its layout half at a third.
  STATUS_ROW_LINK = 'inline-flex items-center gap-2 rounded ' \
                    'focus-visible:outline focus-visible:outline-2 focus-visible:outline-ink focus-visible:outline-offset-2'

  # The box itself, tick included. It was open-coded at two call sites three
  # lines apart, which is two chances for the glyph to differ from the state.
  def time_status_box(state)
    tag.span(class: "#{STATUS_BOX_BASE} #{STATUS_BOX.fetch(state)}") do
      state == :on ? tag.i(class: 'bi bi-check-lg text-[10px]', aria: { hidden: true }) : ''
    end
  end

  # The word beside the box, and the minutes behind it. Mono for the figure
  # because it is a number in a column of numbers the eye compares.
  STATUS_WORD = { on: 'text-cream-900', off: 'text-cream-800', empty: 'text-cream-500' }.freeze
  STATUS_FIGURE = { on: 'text-cream-600', off: 'text-cream-600', empty: 'text-cream-500' }.freeze

  def time_status_word_classes(state) = "text-[13px] #{STATUS_WORD.fetch(state)}"
  def time_status_figure_classes(state) = "font-mono text-xs tabular-nums #{STATUS_FIGURE.fetch(state)}"

  # tag.i, not an html_safe string: the checkbox glyph used to be built by
  # interpolating a literal and calling .html_safe, which is the one erb_lint
  # complaint this file carried.
  # What a pill CHANGES. query_toggle keeps everything else from the live address;
  # the href is the page-load fallback (see lib/query_toggle.js).
  def time_filter_owns(pairs)
    { turbo_frame: '_top', action: 'click->query-toggle#rewrite', query_toggle_owns: pairs.to_json }
  end

  # The status list a pill would produce, computed ONCE: the href (no-JS fallback)
  # and the owns declaration (JS path) both derive from it, so the two ways of
  # following one pill cannot drift apart.
  def time_status_filter_toggle(value, current)
    submitted = Array(request.query_parameters['status_filters']).reject(&:blank?)
    active = submitted.any? ? submitted : Array(current)
    active.include?(value) ? active - [value] : active + [value]
  end

  # The toggle's outcome in owns shape, through the ONE pair encoder
  # (time_filter_owns_pairs below): an empty toggle clears the key, anything
  # else spreads over status_filters[] pairs.
  def time_status_filter_owns_pairs(value, current)
    time_filter_owns_pairs('status_filters' => time_status_filter_toggle(value, current))
  end

  # --- A billing and the filters around it (S4, finding F6) ------------------
  #
  # ONE rule with two halves: a concrete billing and a narrow period or status
  # contradict each other, and the list has no way of saying so while it is
  # happening. Both halves live here, next to each other, because they were
  # written as one thought and only one of them existed.
  #
  # Half one, already in place: while the status filter is exactly "ohne
  # Abrechnung", no billing can be picked at all. A session in a billing is by
  # definition not without one. The controller keeps the same half from the
  # other side (TimeSessionsController#index, "Specific billing" picker): it
  # tailors WHAT the picker lists to the status filter, this predicate decides
  # whether it can be picked at all. Two places, one rule.
  #
  # ⚠️ Renamed in S7 (was time_billing_picker_hidden?). The rule did not change,
  # its ANSWER did: the control used to be dropped from the markup, which made
  # the row jump and said nothing. It now stays in place as a dampened pill that
  # gives the reason (decision E2). "hidden?" stopped being true of it.
  #
  # Half two (D2): picking a concrete billing opens the period to "alles" and
  # switches all three states on, so the billing's hours are actually in the
  # list. It happens in the ADDRESS and not behind the reader's back, so the
  # pills move with it and the reader can put any of them back. Without it, a
  # billing from July picked in September answered with an empty list, and the
  # reader had no way to tell which of two filters was hiding it.
  def time_billing_choice_locked?(status_filters)
    Array(status_filters) == %w[without_billing]
  end

  # Everything a billing choice takes with it, as query_toggle owns-pairs.
  # Choosing a billing IS taking the period and the status filter away, so the
  # pairs are the empty state's two removals (TIME_FILTER_REMOVALS below) in
  # owns shape, not a second list of the same keys. The id itself is NOT here:
  # it is the reader's choice, not part of the rule, and the control carries
  # its own name (lib/query_toggle.js #choiceQuery).
  #
  # The legacy single-value status param goes with them. The filter service no
  # longer listens to it under three open states, but an address should not
  # carry a filter nobody can see.
  #
  # ⚠️ The HASH is the owner, not this method. The view needs it as a hash (to
  # build the href) and as pairs (for the declaration), and it was merging the
  # same two constants a second time to get the hash -- ten lines under a comment
  # saying both come from one merge so they cannot disagree. They agreed by
  # coincidence. One merge now, read from both sides.
  def time_billing_choice_changes
    TIME_FILTER_REMOVALS.fetch(:period).merge(TIME_FILTER_REMOVALS.fetch(:status))
  end

  def time_billing_choice_owns
    time_filter_owns_pairs(time_billing_choice_changes)
  end

  # --- The empty state's removable filters (S3, finding F5) ------------------
  #
  # What "remove this filter" changes in the address, per key. Read from the
  # one owner, TimeSessions::ListFilters, where each removal carries its reason
  # (the project takes the subject along, the status sets all three states).
  # Removing more than was named is safe: every filter is an AND, so a wider
  # removal can only return more rows than the probe found, never fewer.
  TIME_FILTER_REMOVALS = TimeSessions::ListFilters.removals.freeze

  def time_filter_removal_url(key)
    time_list_filter_url(TIME_FILTER_REMOVALS.fetch(key))
  end

  # --- The filter LINE (S7, finding F7) --------------------------------------
  #
  # The filter was a box of three rows sorted by TOPIC: nine period targets, the
  # status, then the selects. It is two rows sorted by INTERACTION now -- what
  # you pick above, what you switch below -- and every choice is a pill that
  # carries its own name, its value and, when it is set, a ✕.
  #
  # That language is not new. S3 gave it to the EMPTY state, where a filter is
  # offered for removal in exactly this shape. Both read the same two owners,
  # TIME_FILTER_REMOVALS for what removing one changes and the label builder
  # below for how it is written, so a filter cannot be called one thing while it
  # narrows the list and another once it has emptied it.
  #
  # ⚠️ The PERIOD is never unset. There is no list without a window, only a
  # different one, so its pill is always filled and never carries a ✕: the ✕
  # would promise a state that does not exist. The way back to the default is
  # the reset link, which is what E5 is about.
  # A Halbgeviertstrich, the typographic sign for a span, not a hyphen and not
  # the Geviertstrich this project keeps out of user-facing text.
  # ⚠️ DOUBLE quotes. In single quotes Ruby does not read the escape, and the
  # pill printed the six characters "\u2013" between the two dates.
  PERIOD_RANGE_DASH = "\u2013"

  # What a pill says. The period speaks in PRESET NAMES here and in dates in the
  # empty state, and the difference is deliberate: picking a filter is choosing
  # among named windows, while a reader staring at an empty list is looking for
  # a booking they can date (the reasoning sits on time_filter_period_value).
  # Since S5a those names have an owner, TimeSessions::ListPeriod, so naming one
  # is no longer the unwhitelisted interpolation S3 decided against.
  def time_filter_line_value(key, state)
    return time_filter_line_period(state) if key == :period

    time_filter_removal_value(key, state)
  end

  # A preset speaks its NAME, a hand-typed period speaks its DATES. Both are
  # what the reader chose: picking "Diesen Monat" is picking that word, while
  # picking a custom period is picking two days, and answering "Eigener
  # Zeitraum" would hide the only thing about it worth reading.
  #
  # Compact, and the year only ONCE ("01.06. - 31.08.2026"): the pill sits in a
  # row of four and a full date on both sides pushes the rest off the line. That
  # is why this is not the empty state's period wording, which spells both years
  # out -- there it is a sentence in a paragraph, here it is a control's face.
  # A half-set period (one bound only) falls back to that wording, which already
  # says "ab" and "bis" properly.
  def time_filter_line_period(state)
    return TimeSessions::ListPeriod.label(state[:date_range]) unless state[:date_range] == TimeSessions::ListPeriod::CUSTOM

    from = state[:start_date]&.to_date
    to = state[:end_date]&.to_date
    # Nothing typed yet: the pill says which MODE it is in, not nothing. The
    # reader has just chosen "eigener Zeitraum" and the fields below are empty;
    # a pill reading only "Zeitraum" would leave them wondering whether the
    # choice took.
    return TimeSessions::ListPeriod.label(TimeSessions::ListPeriod::CUSTOM) if from.nil? && to.nil?
    # One bound only: the empty state's wording already says "ab" and "bis".
    return time_filter_period_value(state[:start_date], state[:end_date]) unless from && to

    # The start drops its year only when the end already carries the same one.
    start_format = from.year == to.year ? :range_start : :range_bound
    "#{l(from, format: start_format)} #{PERIOD_RANGE_DASH} #{l(to, format: :range_bound)}"
  end

  # Name alone while nothing is chosen ("Projekt"), name and value once
  # something is ("Projekt: Shop Relaunch"). Reads the SAME words as the empty
  # state's pills: the keys live under the empty_reason scope for historical
  # reasons, and one vocabulary in a slightly wrongly named scope beats two
  # vocabularies in well named ones (the nine-name lesson from S1).
  def time_filter_line_label(key, state)
    value = time_filter_line_value(key, state)
    name = t("views.organisations.time_sessions.empty_reason.names.#{key}")
    return name if value.blank?
    # ⚠️ The PERIOD wears its value alone, always. "Zeitraum: letzte 90 Tage" is
    # the widest thing in the row and the prefix earns none of that width: a
    # named window and a pair of dates are both unmistakable without it, and the
    # panel's own "Filter" label already says what this row is. The other three
    # keep their name, because "Shop Relaunch" alone would not say which of them
    # it belongs to.
    return value if key == :period

    t('views.organisations.time_sessions.empty_reason.with_value', name: name, value: value)
  end

  # HOW MANY filters DEVIATE FROM THE DEFAULT right now. The mobile badge prints
  # the number, and time_filter_narrowed? is this question asked as a yes or no.
  #
  # ⚠️ Deviation, not narrowing, and the words are not interchangeable: the
  # neutral list (all time, all three states) deviates by two while narrowing
  # nothing at all, so this answers 2 on the widest page there is. That is the
  # right answer for a badge that says "how much of this is not the default",
  # and the wrong one for "is there anything to undo" -- which is why the reset
  # link asks time_filter_reset_offered? and not this. Strict narrowing is no
  # use to either: the DEFAULT period is "this month", which narrows, so a reset
  # would stand on a page nobody has touched. (Reviewed in #693; the split is
  # deliberate and the two part ways exactly here.)
  #
  # It was written out by hand in the view before, which is the third place the
  # same rule was being enforced -- and by then it was wrong: it never counted
  # meeting_id, which S6 turned into a real filter, and never counted
  # creator_id, so "Nur meine Zeiten" narrowed the list behind an unmarked
  # button. A rule enforced in three places by hand is a missing abstraction,
  # and this is what it looked like when it broke. What each filter counts as a
  # deviation is TimeSessions::ListFilters::Filter#deviates? now, one entry per
  # filter, so a new filter cannot be missing from the badge.
  #
  # Asked of the EFFECTIVE state, not of the raw parameters: an unparsable date
  # and an unknown date_range both fall back to the default, so neither can
  # inflate the badge with a filter that is not in force.

  def time_filter_active_count(state)
    count = TimeSessions::ListFilters::ALL.count { |filter| filter.deviates?(state) }
    # ⚠️ A smart folder narrows the list as hard as anything above it, and it was
    # missing here. TimeSessions::EmptyReason leaves it out on purpose, reasoning
    # that "the view answers that with the reset link, which drops the folder
    # too" -- true while that link was unconditional, and false the moment E5
    # made it depend on this count. The result was a narrowed list with a badge
    # reading zero and no way back out offered at all.
    count += 1 if state[:smart_folder].present?
    count
  end

  def time_filter_narrowed?(state)
    time_filter_active_count(state).positive?
  end

  # Where the reset LEADS, as a state: everything, all three states, nothing
  # chosen. Read from the same constant the link is built with, so the question
  # "would following this change anything" cannot answer differently from the
  # link itself.
  def time_filter_reset_target_reached?(state)
    # The neutral list has no folder either: time_list_path with the neutral
    # params carries none, so following the link really does leave one.
    return false if state[:smart_folder].present?

    TimeSessions::ListFilters::ALL.all? { |filter| filter.neutral?(state) }
  end

  # Whether the reset is offered at all. TWO conditions, and each answers a
  # different question the other cannot:
  #
  #   narrowed?      -- has the reader moved off the default? Without this the
  #                     link stands on a page nobody has filtered, offering to
  #                     undo nothing.
  #   target_reached -- would following it change anything? Without this the
  #                     link SURVIVES ITS OWN CLICK: the neutral list it leads to
  #                     is all time and all three states, which deviates from the
  #                     default by two, so the reset re-rendered on the widest
  #                     possible list and pointed at the page already shown.
  #                     (Found in review of #693.)
  def time_filter_reset_offered?(state)
    time_filter_narrowed?(state) && !time_filter_reset_target_reached?(state)
  end

  # The period presets used to live here as TIME_FILTER_RANGE_KEYS. They are
  # TimeSessions::ListPeriod::KEYS now: the same eight keys in the same order,
  # plus the labels, the windows, the two defaults and the whitelist. The status
  # table above the list needs all of that, and two owners for one vocabulary is
  # the thing this constant was introduced to stop.

  # A period segment's change: the period removal with a range in it. ONE owner
  # for "a new range clears the hand-set bounds"; the href and the owns
  # declaration of every segment in _filter_pills derive from it.
  def time_period_change(range_key)
    TIME_FILTER_REMOVALS.fetch(:period).merge('date_range' => range_key)
  end

  # One filter change, from the Hash shape time_list_filter_url takes (nil
  # clears a key, an Array is a multi-value key) into the [key, value] pairs
  # lib/query_toggle.js reads: "" for a cleared key, one "key[]" pair per array
  # element, and a "key[]" cleared for an empty array. The href (no-JS fallback)
  # and the owns declaration (live rewrite) of one control come from ONE Hash
  # this way, so the two ways of following it cannot drift apart.
  def time_filter_owns_pairs(changes)
    changes.flat_map do |key, value|
      case value
      when Array then value.empty? ? [["#{key}[]", '']] : value.map { |v| ["#{key}[]", v.to_s] }
      when nil then [[key.to_s, '']]
      else [[key.to_s, value.to_s]]
      end
    end
  end

  # What a filter is CALLED, with its own value in it: "Abrechnung: August 2026"
  # rather than "Abrechnung". Naming the value is the whole point of the empty
  # state -- a reader who set three filters has to recognise which one this is.
  #
  # A filter whose value has no name to print falls back to the bare name. That
  # covers "nur meine Zeiten", which has no value, and a record the reader may
  # not read (the controller looks all three up through their own policy scope).
  #
  # `state` carries everything the labels need and is gathered by the view: the
  # period bounds, the three records whose names are printed, the states that are
  # switched on, and the search term. Handed in rather than read off the
  # controller, so these stay plain functions of their arguments -- a helper that
  # reaches for @ivars is a helper that can only be called from one page.
  #
  # No `private` below either: this is a helper module, everything in it is mixed
  # into the view, and a private section here would silently take the public
  # helpers that follow it with it.
  def time_filter_removal_label(key, state)
    scope = 'views.organisations.time_sessions.empty_reason'
    # The creator filter has two names and no value: "Nur meine Zeiten" is true
    # of the reader's own id only, and the id is typeable (the assistant's
    # report links here with a colleague's). Nobody's name is printed for the
    # other case: resolving a typed id to a person would make the pill a lookup
    # service, the line assistant_report_filter_summary draws as well.
    other_person = key == :creator && !state[:creator_mine]
    # Since the person filter (D5 of doc/zeiten_weitere_filter_plan.md) a
    # colleague IS named, but only one the controller found among the people
    # whose time the reader may see; anyone else keeps the neutral name.
    return t("#{scope}.with_value", name: t("#{scope}.person"), value: viewer_display_name(state[:person])) if other_person && state[:person]

    name = other_person ? t("#{scope}.creator_other") : t("#{scope}.names.#{key}")
    value = time_filter_removal_value(key, state)

    value.present? ? t("#{scope}.with_value", name: name, value: value) : name
  end

  # The filters "+ Filter" offers right now (plan step 1, D3). A kind that is
  # already chosen has its own pill and is not offered twice. The person needs
  # someone besides the reader: the reader's own name is the switch
  # "Nur meine Zeiten". Asked as "anyone else", not as "two people", because a
  # reader who sees only a colleague's time and has none of their own still has
  # someone to choose (review, 29.09.2026).
  #
  # A tag needs a tag to offer (load_filter_tags), nothing more: a reader who
  # sees only their own time may still sort it by tag. The ticket phase needs a
  # booking on a ticket (ticket_phase: true), or every phase answers empty.
  def time_filter_addable_kinds(state, people:, reader:, tags:, ticket_phase:)
    kinds = []
    kinds << :person if state[:person].nil? && people.any? { |person| person.id != reader.id }
    kinds << :tag if state[:tag].nil? && tags.any?
    # A phase or a concrete value (step 3b) is the one ticket status pill.
    kinds << :ticket_phase if state[:phase].nil? && state[:ticket_status_choice].nil? && ticket_phase
    kinds
  end

  def time_filter_removal_value(key, state)
    case key
    when :period then time_filter_period_value(state[:start_date], state[:end_date])
    when :project then state[:project]&.name
    # One pill for both subject types, so one label. This is a PRECEDENCE, not
    # a claim that only one of the two can be set: the label renders only in the
    # empty state, so the both-set case -- which is always empty, the database
    # forbids a booking with two subjects -- is exactly where it runs. Naming
    # one of them is enough because the removal beside it clears BOTH.
    when :subject then time_session_subject_presentation(state[:ticket] || state[:meeting])&.label
    when :billing then state[:group]&.name
    when :tag then state[:tag]&.name
    # A phase and a value replace each other in the menus; both at once is only
    # ever typed, and the phase is then named (the removal clears both).
    when :ticket_phase
      state[:phase] ? TimeSessions::TicketPhase.label(state[:phase]) : state[:ticket_status_choice]&.label
    when :status then time_filter_status_value(state[:status_filters])
    when :search then state[:search]
    end
  end

  # The window in dates, not the name of the preset that produced it. A name
  # would have to come from a key built out of params[:date_range], which nothing
  # whitelists, and "diesen Monat" answers a smaller part of the reader's
  # question than the dates do: they are looking for a booking they can date.
  # The year is spelled out on both bounds -- date.formats.short carries none,
  # and a period without one is ambiguous the moment January comes round.
  def time_filter_period_value(start_date, end_date)
    scope = 'views.organisations.time_sessions.empty_reason'
    from = start_date && l(start_date.to_date)
    to = end_date && l(end_date.to_date)

    if from && to then t("#{scope}.period_between", from: from, to: to)
    elsif from then t("#{scope}.period_from", date: from)
    elsif to then t("#{scope}.period_to", date: to)
    end
  end

  # The states that are switched ON, in the canonical order, each through the one
  # helper that turns a state into a word (S1). Reading the constant rather than
  # the parameter keeps the order the page reads in, whatever order the
  # parameters arrived in.
  def time_filter_status_value(active_states)
    active = Array(active_states)
    TimeSession::BILLING_STATUS_FILTERS.select { |state| active.include?(state) }
                                       .map { |state| time_billing_state_label(state) }
                                       .join(', ')
  end

  # The billing state as a word. THE one place a billing state turns into text:
  # the filter pills, the overview table, the time list, the ticket table's
  # billing column, the hours chip, the billings list, the assistant report and
  # both dashboard widgets all come through here, so none of them can invent a
  # fifth German word for the same thing (S1 of the filter-line plan; before it
  # the three states were named in nine places).
  #
  # The minutes of ONE column of the status table for one project row of
  # TimeSessionStatisticsService (a { project:, durations:, total_duration: }
  # hash): a bucket column reads its own sum, the total column
  # (TimeSession::BILLING_OVERVIEW_TOTAL) the row's total. Body and foot of the
  # table read their cells through this, so "which figure stands in which
  # column" is spelled once. `fetch`: an unknown column is a bug, not a dash.
  def time_overview_column_minutes(stat, column)
    return stat[:total_duration] if column == TimeSession::BILLING_OVERVIEW_TOTAL

    stat[:durations].fetch(column)
  end

  # Takes a bucket ('without_billing' / 'in_billing' / 'billed', the keys of
  # TimeSession::BILLING_STATUS_FILTERS) or a subject-level status from
  # TimeSessions::SubjectBillingStatus, which are the same words plus :mixed and
  # :no_sessions. A mixed row says how far it got rather than just "mixed", and
  # falls back to the plain word when nothing is invoiced yet and there is no
  # share to name.
  def time_billing_state_label(state, percent: nil)
    scope = 'views.time_sessions.billing_status'
    return nil if state.nil? || state == :no_sessions
    return t("#{scope}.#{state}") unless state == :mixed
    return t("#{scope}.mixed") if percent.nil?

    t("#{scope}.partial", percent: percent)
  end

  # Minutes as a clock reading: 108 -> "1:48". The one spelling for durations the
  # reader compares (header chip, capture popover); no leading zero on the hour,
  # unlike TimeSession.format_duration's "01:48" in the table columns. The unit
  # ("h") is the caller's, because it is markup, not value.
  def time_clock_label(minutes)
    total = minutes.to_i
    format('%<hours>d:%<minutes>02d', hours: total / 60, minutes: total % 60)
  end

  # The one address of the capture popover frame: the chip's frame src, the
  # row edit links and the edit form's cancel all build it here.
  def subject_popover_path_for(subject, edit: nil)
    subject_param = subject.is_a?(Meeting) ? { meeting_id: subject.id } : { ticket_id: subject.id }
    subject_popover_organisation_time_sessions_path(
      subject.organisation, project_id: subject.project_id, edit: edit, **subject_param
    )
  end

  # One rule for "may this row be reworked from the popover": only OPEN time
  # (designer, 05.09.2026 — a row assigned to a billing is changed in the
  # billing, its title says so), and only by its creator or an account admin
  # (authorize_creator!'s rule). The popover rows, the timeline pencil and the
  # controller all read it — the same question, one owner.
  def subject_popover_row_editable?(session)
    session.editable? && !session.grouped? &&
      (session.creator_id == current_user.id || current_user.account_admin_in?(session.organisation))
  end

  # How much time each open billing already holds, in ONE query. The panel lists
  # the billings to choose from, and TimeSessionGroup#total_duration is a sum per
  # record, so asking it per row is a query per row.
  #
  # The design draft puts a STATUS in this column ("offen" / "eingereicht"). This
  # app has no such thing: a billing is billed or it is not, and this list only
  # ever holds the ones that are not, so the column would say the same word on
  # every line. The total is the number that actually helps somebody pick.
  #
  # policy_scope, not the bare relation: the number is org-wide booked time, and
  # without it somebody who may see only their own hours read everybody's out of
  # this column. Scoped, it means "what you can see in there", which is exactly
  # what they get when they open the billing, so the two agree.
  def unbilled_time_session_group_minutes
    @unbilled_time_session_group_minutes ||=
      policy_scope(TimeSession)
      .where(time_session_group_id: unbilled_time_session_groups.map(&:id))
      .group(:time_session_group_id)
      .sum(:duration)
  end

  # Select collections of the forms — here instead of as an inline query in the view.
  def unbilled_time_session_groups
    @unbilled_time_session_groups ||= TimeSessionGroup.unbilled.ordered
  end

  def selectable_tickets_for(project)
    project.tickets.includes(:assignees).order(updated_at: :desc).limit(200)
  end
end

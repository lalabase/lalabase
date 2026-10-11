# frozen_string_literal: true

require 'rails_helper'

# What: A meeting's hours are reachable by the meeting's OWN filter (S6 of
#       doc/zeiten_filterzeile_und_stand_plan.md), from the link the hours chip
#       builds to the list that answers it and the empty state that names it.
# Type: Request spec, because the promise spans four places that all have to
#       agree about one parameter: the link helper, the filter service, the form
#       that carries the filter across a submit, and the empty state's label.
# Why:  Before S6 a meeting travelled as `search: <title>`. That is not a filter
#       but a coincidence: two meetings with the same title both answered, a
#       renamed meeting stopped answering its own link, and a booking that only
#       MENTIONS the title answered too. The number beside the link is computed
#       from the meeting id, so the link has to be.
RSpec.describe 'Time list: a meeting is a real filter', type: :request do
  # The helper under test, called directly: it reads no request and no current
  # user, which is the property that lets link builders with no view at all use
  # it (Lalabase::RouteContext, the citation links).
  include TimeListHelper

  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    sign_in admin
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  # Same title, same project, two meetings. This is the case the title search
  # could not tell apart, and everything below turns on it.
  let(:meeting)  { with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Kickoff Sanierung') } }
  let(:namesake) { with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Kickoff Sanierung') } }

  let!(:meeting_session) do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            meeting: meeting, duration: 45, description: 'Protokoll')
    end
  end

  let!(:namesake_session) do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            meeting: namesake, duration: 90, description: 'Protokoll')
    end
  end

  # A booking with no subject at all, and one whose DESCRIPTION carries the
  # title. Both answered the old title search; neither is this meeting's time.
  let!(:subjectless_session) do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            duration: 15, description: 'Kickoff Sanierung nachbereitet')
    end
  end

  # A ticket in the same project, with its own booked time. Each subject filter
  # finds something on its own, which is what makes their COMBINATION the
  # interesting case below.
  let(:ticket) { with_tenant { create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Fundament') } }

  let!(:ticket_session) do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            ticket: ticket, duration: 30, description: 'Ticketzeit')
    end
  end

  def get_list(params = {})
    get organisation_time_sessions_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  describe 'the link a meeting builds' do
    # The helper is the ONE address of a subject's hours; the hours chip, the
    # ticket table's time column and the assignment popover all go through it.
    let(:path) { subject_time_list_path(meeting) }

    it 'carries the meeting id, not a search for its title' do
      expect(path).to include("meeting_id=#{meeting.id}")
      expect(path).not_to include('search=')
    end

    it 'answers with exactly this meeting\'s minutes, not its namesake\'s' do
      get path

      expect(response).to have_http_status(:ok)
      expect(assigns(:total_filtered_duration)).to eq(45)
    end

    # The counter-half: the address the helper used to build cannot tell the two
    # apart. If this ever comes back 45, the ambiguity is gone and the argument
    # for the id can be revisited.
    it 'is not a distinction the old title search could make' do
      get organisation_time_sessions_path(organisation, project_id_filter: project.id, search: meeting.title,
                                                        **TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)

      expect(assigns(:total_filtered_duration)).to eq(150)
    end
  end

  describe 'the list under the filter' do
    it 'excludes the namesake, the ticket time and the subjectless booking' do
      get_list(meeting_id: meeting.id, status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(assigns(:total_filtered_duration)).to eq(45)
    end

    it 'finds nothing for a junk id instead of ignoring it' do
      get_list(meeting_id: SecureRandom.uuid, status_filters: TimeSession::BILLING_STATUS_FILTERS,
               date_range: 'all')

      expect(assigns(:total_filtered_duration)).to eq(0)
    end

    # The value that is no uuid AT ALL, which the example above does not reach:
    # SecureRandom.uuid is a well-formed id that merely matches nothing. Rails
    # casts an unparseable uuid to nil and BINDS it, so the column is compared
    # against NULL and nothing matches. It does not become `IS NULL`, which
    # would answer a "one meeting" address with every booking that has no
    # subject at all (here: 15 minutes).
    it 'finds nothing for a value that is no uuid at all' do
      ['abc', '42', 'Kickoff Sanierung'].each do |junk|
        get_list(meeting_id: junk, status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

        expect(assigns(:total_filtered_duration)).to eq(0), "meeting_id=#{junk.inspect} hat gefiltert"
      end
    end

    # Cross-tenant: a meeting id from another organisation is not a way into
    # this one's hours, and not a 500 either.
    it 'ignores a meeting of another organisation, quietly and emptily' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        foreign_project = create(:project, organisation: other_org)
        create(:meeting, project: foreign_project, organisation: other_org, title: 'Fremd')
      end

      get_list(meeting_id: foreign.id, status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(assigns(:total_filtered_duration)).to eq(0)
      # The duration alone does not guard this: it is 0 whether the meeting is
      # looked up through policy_scope(Meeting) or through Meeting.find_by. What
      # the policy scope protects is the TITLE, and the empty state really does
      # print it -- the example below proves that for a readable meeting.
      expect(response.body).not_to include('Fremd'),
                                   'the empty state names a meeting of another organisation'
    end
  end

  # The filter has no control of its own until S7, so the form has to carry it.
  # Without the hidden field it falls off the very next submit and the list
  # silently widens: nothing on the page would say why the number changed.
  describe 'surviving a filter submit' do
    # ⚠️ Found by data-filter-state, NOT by name and not by the form it sits in.
    # The header search form re-emits every query parameter as a hidden field
    # (index.html.erb, out of request.query_parameters), so it carries a
    # meeting_id of its own under the SAME name, it posts to the SAME address as
    # the filter form, and it comes EARLIER in the document. A name selector
    # finds that copy, and so does one scoped by form action. Deleting the line
    # under test changed nothing either of my first two selectors could see.
    def preserved_meeting_field
      Nokogiri::HTML(response.body).at_css('input[type="hidden"][data-filter-state="meeting_id"]')
    end

    it 'is carried by the filter form as a hidden field' do
      get_list(meeting_id: meeting.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(preserved_meeting_field).to be_present,
                                         'the meeting filter would fall off the next filter submit'
      expect(preserved_meeting_field['value']).to eq(meeting.id)
    end

    it 'renders no such field when no meeting is filtered' do
      get_list(project_id_filter: project.id)

      expect(preserved_meeting_field).to be_nil
    end

    # A subject belongs to a project, so a project change clears both ids. The
    # rule lives in Ruby (TimeSession::SUBJECT_FILTER_PARAMS) and used to reach a
    # JavaScript cascade as a data value. With S7 the project is a menu of LINKS,
    # so the rule travels in the address itself -- which also means it now holds
    # without JavaScript, where the cascade never ran at all.
    #
    # Both halves are checked, because they are two different promises: the href
    # is what a browser follows, the owns declaration is what query-toggle
    # rewrites against the live address. One without the other is a filter that
    # clears the subject on a first click and puts it back on the second.
    it 'clears both subject ids when another project is picked, in href and in owns' do
      other = with_tenant { create(:project, organisation: organisation) }
      get_list(project_id_filter: project.id, meeting_id: meeting.id)

      option = Nokogiri::HTML(response.body)
                       .at_css("[data-filter-pill=\"project\"] a[data-filter-pill-option=\"#{other.id}\"]")
      expect(option).to be_present

      href = Rack::Utils.parse_nested_query(URI.parse(option['href']).query)
      expect(href).to include('project_id_filter' => other.id)
      expect(href.keys).not_to include('ticket_id', 'meeting_id')

      owns = JSON.parse(option['data-query-toggle-owns'])
      expect(owns).to include(['ticket_id', ''], ['meeting_id', ''], ['project_id_filter', other.id])
    end
  end

  describe 'the empty state' do
    # The empty state names a filter only when TAKING IT AWAY brings rows back
    # (EmptyReason is drop-one). So the meeting has to be the thing that emptied
    # the list: one with no bookings at all, while the project around it has
    # plenty. An impossible PERIOD would make the period the only culprit and
    # say nothing about the subject -- which is what my first version of this
    # example did, and it passed for the wrong reason until it did not.
    let(:unbooked) do
      with_tenant do
        create(:meeting, project: project, organisation: organisation, creator: admin,
                         title: 'Sitzung ohne gebuchte Zeit')
      end
    end

    it 'names the meeting by title and gives it back' do
      get_list(meeting_id: unbooked.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(assigns(:total_filtered_duration)).to eq(0)
      expect(response.body).to include(ERB::Util.html_escape(unbooked.title)),
                               'the empty state does not name the meeting it filtered by'
    end

    # The oracle is the LINK, not the sentence, the same rule the S3 empty-state
    # spec follows: a pill that leads to another empty list is the failure worth
    # catching. The offers are read back by data-empty-filter, as they are there.
    it 'offers a way back that really fills the list again' do
      get_list(meeting_id: unbooked.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      offers = Nokogiri::HTML(response.body).css('a[data-empty-filter]').to_h do |link|
        [link['data-empty-filter'], CGI.unescapeHTML(link['href'])]
      end
      expect(offers).to have_key('subject'), "no subject removal offered, only #{offers.keys}"
      expect(offers['subject']).not_to include('meeting_id=')

      get offers['subject']
      expect(response).to have_http_status(:ok)
      expect(assigns(:total_filtered_duration)).to be > 0
    end

    it 'offers a removal that takes both subject ids with it' do
      removal = TimeSessionsHelper::TIME_FILTER_REMOVALS.fetch(:subject)

      expect(removal.keys).to match_array(TimeSession::SUBJECT_FILTER_PARAMS)
      expect(removal.values).to all(be_nil)
    end

    it 'takes the subject with the project, both ids' do
      removal = TimeSessionsHelper::TIME_FILTER_REMOVALS.fetch(:project)

      expect(removal.keys).to include(*TimeSession::SUBJECT_FILTER_PARAMS)
    end
  end

  # The dead end S6 opens: the meeting filter has no control of its own until
  # S7, but the ticket select beside it can still ADD to it. Both subject ids on
  # one address is a query the DATABASE forbids (check constraint
  # time_sessions_single_subject), so it is empty for good -- and the empty
  # state offers ONE subject removal, which drops the ticket the reader just
  # picked along with the meeting.
  #
  # The oracle is the DECLARATION the select carries, not the empty list: what
  # goes wrong is a control building an address, and lib/query_toggle.js is the
  # single place that turns such a declaration into one. The address itself is
  # pinned by its node test (spec/javascript/lib/query_toggle.test.js), so the
  # two halves of the promise are held by the two suites that can see them.
  describe 'choosing a ticket while a meeting is filtered' do
    # ⚠️ Read off the subject pill's OPTION since S7. The rule is unchanged and
    # so is what it defends; only its carrier moved. It was a select declaring
    # the rule once for whatever the reader picked, found by data-filter-control
    # because the billing select declared one too and came first in the
    # document. There are no selects and no first-or-second any more: every
    # option is its own declaration.
    def ticket_choice_owns
      element = Nokogiri::HTML(response.body)
                        .at_css(%([data-filter-pill="subject"] a[data-filter-pill-option="#{ticket.id}"]))
      element && JSON.parse(element['data-query-toggle-owns'])
    end

    it 'declares that picking a ticket takes the meeting filter with it' do
      get_list(meeting_id: meeting.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(ticket_choice_owns).to include(['meeting_id', '']),
                                    'picking a ticket would keep the meeting filter and empty the list for good'
    end

    # The counter-half, and the reason the declaration is not decoration: each
    # filter answers on its own, both together answer never.
    it 'is the query no booking can satisfy, which is why that declaration matters' do
      get_list(meeting_id: meeting.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')
      expect(assigns(:total_filtered_duration)).to eq(45)

      get_list(ticket_id: ticket.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')
      expect(assigns(:total_filtered_duration)).to eq(30)

      get_list(meeting_id: meeting.id, ticket_id: ticket.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')
      expect(assigns(:total_filtered_duration)).to eq(0)
    end
  end

  # On a phone the badge is the ONLY thing that says a filter is set at all: the
  # drawer is closed, so no select and no pill is on screen. Before S6 the
  # meeting travelled as a title search and the badge counted it; a badge that
  # knows ticket_id only counts one LESS for the very same narrowing.
  #
  # Read by data-filter-count, a handle of its own: the number is printed in a
  # span whose only other mark is its styling, and a spec that greps for a "4"
  # in the page body finds every 4 on it.
  describe 'the mobile filter badge' do
    def badge_count
      Nokogiri::HTML(response.body).at_css('[data-filter-count]')&.[]('data-filter-count')
    end

    # period ("alles" is not the default month) + status (three states is not
    # the default two) + project + Bezug.
    it 'counts the meeting as the Bezug filter it is' do
      get_list(meeting_id: meeting.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(badge_count).to eq('4')
    end

    # ONE pill, ONE removal, ONE label -- so one count. The two ids are one
    # "Bezug" everywhere else the reader meets them.
    it 'counts the two subject ids as one filter, the way the pill and the removal do' do
      get_list(meeting_id: meeting.id, ticket_id: ticket.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(badge_count).to eq('4')
    end

    it 'counts the person filter, which it also used to miss' do
      get_list(creator_id: admin.id, project_id_filter: project.id,
               status_filters: TimeSession::BILLING_STATUS_FILTERS, date_range: 'all')

      expect(badge_count).to eq('4')
    end
  end
end

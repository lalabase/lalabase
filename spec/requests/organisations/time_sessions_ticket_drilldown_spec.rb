# frozen_string_literal: true

require 'rails_helper'

# What: The way from a ticket to its booked time, now that the project's own
#       times page is gone (doc/zeiten_eine_liste_plan.md, S3b). The hours chip
#       on the ticket, the time column of the ticket table and the assignment
#       popover all open the ORGANISATION list, with project and ticket
#       preselected and the list defaults neutralised.
# Type: Request spec, end to end: the href is read off the rendered ticket
#       page, then followed. The sum the list shows must be the chip's number,
#       for an admin and for someone who may only see their own hours.
RSpec.describe 'Ticket to time list drill-down', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:own_viewer)   { create(:user) }
  let(:colleague)    { create(:user) }

  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'Kesselhaus') } }
  let(:ticket)       { with_tenant { create(:ticket, project: project, creator: admin, title: 'Kessel flicken') } }
  let(:other_ticket) { with_tenant { create(:ticket, project: project, creator: admin, title: 'Dach decken') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: own_viewer, organisation: organisation, role: member_role, active: true)
      create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
      create(:time_session_permission, user: own_viewer, project: project, can_view_own: true, can_view_all: false)
    end
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(minutes, creator:, on: ticket, billed: false, group: nil, at: Time.current)
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: creator, ticket: on,
                            duration: minutes, billed: billed, time_session_group: group, occurred_on: at)
    end
  end

  # Three bookings on the ticket in all three billing states, one of them two
  # months old, one of them foreign; plus a booking on ANOTHER ticket. Every one
  # of the list's defaults (current month, billed hidden) and the ticket filter
  # has to be in effect for the sum to come out right.
  before do
    billed_group   = with_tenant { create(:time_session_group, :billed, organisation: organisation) }
    unbilled_group = with_tenant { create(:time_session_group, organisation: organisation) }
    book(10, creator: own_viewer, billed: true, group: billed_group, at: 2.months.ago)
    book(20, creator: own_viewer)
    book(30, creator: colleague, group: unbilled_group)
    book(40, creator: own_viewer, on: other_ticket)
  end

  def hrefs_of(body)
    body.scan(/href="([^"]+)"/).flatten.map { |href| CGI.unescapeHTML(href) }
  end

  # What a filter pill says it is set to. The filters used to be selects and the
  # answer was the option carrying `selected`; since S7 they are pills whose
  # menu marks the chosen option with aria-current. The question is the same:
  # "did the drill-down arrive with this filter applied".
  def chosen_filter(body, key)
    Nokogiri::HTML(body)
            .at_css(%([data-filter-pill="#{key}"] a[aria-current="true"][data-filter-pill-option]))
            &.[]('data-filter-pill-option')
  end

  # The chip is a button for everybody now; the way into the time list is the
  # footer link of its capture popover (a lazy turbo-frame). This walks the same
  # two steps the browser walks: read the frame src off the ticket page, fetch
  # the popover, read the drill-down link out of it.
  def chip_href
    get organisation_project_ticket_path(organisation, project, ticket)
    expect(response).to have_http_status(:ok)
    chip = Nokogiri::HTML(response.body).css("[class*='js-time-chip-#{ticket.id}']").first
    expect(chip).to be_present, 'the ticket page renders no hours chip'
    frame_src = chip.at_css('turbo-frame')&.[]('src')
    expect(frame_src).to be_present, 'the hours chip carries no popover frame'

    get CGI.unescapeHTML(frame_src)
    expect(response).to have_http_status(:ok)
    # Not the first a[href*=ticket_id]: the rows carry edit links with the same
    # param. The footer link is the one whose path is the times list.
    link = Nokogiri::HTML(response.body).css('a[href*="ticket_id="]').find do |candidate|
      URI.parse(CGI.unescapeHTML(candidate['href'])).path == organisation_time_sessions_path(organisation)
    end
    expect(link).to be_present, 'the capture popover carries no link into the time list'
    CGI.unescapeHTML(link['href'])
  end

  context 'as account admin' do
    before { sign_in admin }

    it 'opens the organisation list, not the project page, with project and ticket preselected' do
      href = chip_href
      expect(URI.parse(href).path).to eq(organisation_time_sessions_path(organisation))

      get href
      expect(response).to have_http_status(:ok)
      expect(chosen_filter(response.body, 'project')).to eq(project.id)
      expect(chosen_filter(response.body, 'subject')).to eq(ticket.id)
    end

    it 'sums to the chip number: all three bookings on the ticket, none of the other ticket' do
      get chip_href

      chip = with_tenant { SubjectTimeSummaryService.call(subject: ticket, user: admin) }
      expect(chip[:total_minutes]).to eq(60)
      expect(assigns(:total_filtered_duration)).to eq(60)
    end

    it 'keeps project and ticket when a pill is toggled' do
      get chip_href

      pill = hrefs_of(response.body).find { |href| href.include?("creator_id=#{admin.id}") }
      expect(pill).to be_present, 'no "only my time" pill on the list'
      expect(pill).to include("project_id_filter=#{project.id}")
      expect(pill).to include("ticket_id=#{ticket.id}")
    end

    # Two doors, one address. The table column used to build its own link.
    it 'the ticket table column carries the same address as the popover footer' do
      href = chip_href

      with_tenant do
        ViewConfiguration.create!(user: admin, project: project, view_type: 'tickets',
                                  table_columns: %w[number title time_spent],
                                  list_columns: { 'cells' => [], 'metadata' => [] },
                                  header_columns: %w[assignees])
      end
      get organisation_project_tickets_path(organisation, project)
      column_link = hrefs_of(response.body).find { |link| link.include?("ticket_id=#{ticket.id}") }
      expect(column_link).to eq(href)
    end
  end

  context 'as someone who may only see their own hours' do
    before { sign_in own_viewer }

    # The address is the same for everybody; the list narrows, not the link.
    it 'sums to THEIR chip number: own bookings on the ticket only' do
      get organisation_time_sessions_path(organisation, project_id_filter: project.id, ticket_id: ticket.id,
                                                        **TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)
      expect(response).to have_http_status(:ok)

      chip = with_tenant { SubjectTimeSummaryService.call(subject: ticket, user: own_viewer) }
      expect(chip[:total_minutes]).to eq(30)
      expect(assigns(:total_filtered_duration)).to eq(30)
    end
  end
end

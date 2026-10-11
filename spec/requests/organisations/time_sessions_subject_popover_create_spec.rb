# frozen_string_literal: true

require 'rails_helper'

# What: Saving from the capture popover (context=subject_popover). The feedback
#       happens where the click was (designer handoff §9): the popover frame
#       re-renders whole (new row on top, sums grown, fresh form), the chip
#       updates only its VALUE span, and the timeline frame reloads — while the
#       old full ticket_display_frame update must NOT run, because it would
#       tear down the open popover.
# Type: Request spec against POST create, asserting the turbo-stream targets.
RSpec.describe 'Organisations::TimeSessions subject popover create', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }

  let(:project) { with_tenant { create(:project, organisation: organisation, name: 'Kesselhaus') } }
  let(:ticket)  { with_tenant { create(:ticket, project: project, creator: admin, title: 'Kessel flicken') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    Prosopite.pause
    sign_in admin
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def capture(overrides = {})
    post organisation_time_sessions_path(organisation),
         params: {
           context: 'subject_popover',
           time_session: {
             duration_string: '0:30', occurred_on: Date.current.to_s,
             description: 'Farbreihenfolge geprüft',
             project_id: project.id, ticket_id: ticket.id
           }.merge(overrides)
         },
         headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
  end

  def stream_targets
    Nokogiri::HTML(response.body).css('turbo-stream').map { |node| [node['action'], node['target']] }
  end

  it 'saves and streams to the popover frame, the chip value span and the timeline — never the display frame' do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin,
                            ticket: ticket, duration: 78, description: 'Alte Buchung', occurred_on: 2.days.ago)
    end

    expect { capture }.to change { with_tenant { ticket.time_sessions.count } }.by(1)
    expect(response).to have_http_status(:ok)

    expect(stream_targets).to include(['update', "subject_time_popover_#{ticket.id}"],
                                      ['update', "subject_time_chip_value_#{ticket.id}"],
                                      ['replace', "ticket-timeline-#{ticket.id}"])
    expect(response.body).not_to include('ticket_display_frame')

    # Inside the re-rendered popover: the new row on top, the sum grown to
    # 78 + 30 = 108 minutes.
    popover = Nokogiri::HTML(response.body).at_css("turbo-stream[target='subject_time_popover_#{ticket.id}']")
    expect(popover.css('li').first.text).to include('Farbreihenfolge geprüft')
    expect(popover.text).to include('1:48')

    chip_value = Nokogiri::HTML(response.body).at_css("turbo-stream[target='subject_time_chip_value_#{ticket.id}']")
    expect(chip_value.text).to include('1:48')
  end

  it 'keeps the popover open on validation errors: 422, the frame re-renders with the errored form' do
    expect { capture(duration_string: '0:00') }.not_to(change { with_tenant { TimeSession.count } })
    expect(response).to have_http_status(:unprocessable_content)

    expect(stream_targets).to include(['update', "subject_time_popover_#{ticket.id}"])
    expect(response.body).not_to include('ticket_display_frame')
  end

  # The duration validation has two edges (greater_than: 0, at most
  # MAX_DURATION_MINUTES). 0:00 above covers the reject side of the lower edge;
  # these pin the accept sides and the upper edge, so flipping either operator
  # (> to >=, <= to <) turns one of them red. Raw minute strings on purpose:
  # parse_duration_string reads them, and they hit the boundary exactly.
  it 'accepts the smallest bookable duration, one minute (lower boundary)' do
    expect { capture(duration_string: '0:01') }
      .to change { with_tenant { ticket.time_sessions.count } }.by(1)
    expect(response).to have_http_status(:ok)
    expect(with_tenant { ticket.time_sessions.order(:created_at).last.duration }).to eq(1)
  end

  it 'accepts exactly the duration cap and rejects one minute above (upper boundary)' do
    expect { capture(duration_string: TimeSession::MAX_DURATION_MINUTES.to_s) }
      .to change { with_tenant { ticket.time_sessions.count } }.by(1)

    expect { capture(duration_string: (TimeSession::MAX_DURATION_MINUTES + 1).to_s) }
      .not_to(change { with_tenant { ticket.time_sessions.count } })
    expect(response).to have_http_status(:unprocessable_content)
  end

  context 'with a meeting subject' do
    let(:meeting) { with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin) } }

    it 'streams to the meeting popover and value span, not to the full meeting chip wrapper' do
      post organisation_time_sessions_path(organisation),
           params: {
             context: 'subject_popover',
             time_session: { duration_string: '0:45', occurred_on: Date.current.to_s,
                             description: 'Besprochen', project_id: project.id, meeting_id: meeting.id }
           },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(stream_targets).to include(['update', "subject_time_popover_#{meeting.id}"],
                                        ['update', "subject_time_chip_value_#{meeting.id}"])
      expect(response.body).not_to include("meeting_#{meeting.id}_time_summary")
    end
  end
end

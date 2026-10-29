# frozen_string_literal: true

require 'rails_helper'

# What: POST /api/v1/tickets/:ticket_id/time_sessions books by the rule the MCP
#       tool create_time_session books by (TimeSessions::Booking, cli_rest_plan R6).
# Type: Request spec.
# Why:  The terminal client books time over REST. Before R6 REST saved raw (no
#       billed guards), dated a booking "now" instead of the day in the person's
#       zone, read an unusable date as "now" and let duration_string silently win
#       over duration_minutes. A booking is money: the day decides the invoice.
RSpec.describe 'API V1 time booking', :ci_guard, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, timezone: 'Europe/Berlin', language_preference: 'en') }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, creator: user) }
  end
  let(:read_only) { false }
  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only)
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
      create(:time_session_permission, user: user, project: project, can_create_own: true)
    end
  end

  def book(ticket_id: ticket.id, **time_session)
    post "/api/v1/tickets/#{ticket_id}/time_sessions", params: { time_session: time_session },
                                                       headers: { 'Authorization' => "Bearer #{pat.token}" }
  end

  def body
    JSON.parse(response.body)
  end

  def bookings
    ActsAsTenant.without_tenant { TimeSession.where(ticket_id: ticket.id).count }
  end

  def booked
    ActsAsTenant.without_tenant { TimeSession.find(body.dig('data', 'id')) }
  end

  describe 'the duration' do
    { { duration_string: '30' } => 30, { duration_string: '1:30' } => 90, { duration_string: '1.5' } => 90,
      { duration_minutes: 45 } => 45, { duration_string: '24:00' } => 1440 }.each do |input, minutes|
      it "books #{input.inspect} as #{minutes} minutes" do
        book(**input)
        expect(response).to have_http_status(:created)
        expect(body.dig('data', 'duration_minutes')).to eq(minutes)
      end
    end

    it 'refuses both durations instead of letting one win, writing nothing' do
      expect { book(duration_string: '1:30', duration_minutes: 45) }.not_to(change { bookings })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to eq('error' => 'validation_failed', 'code' => 'invalid_input',
                         'errors' => [I18n.t('services.time_session_booking.both_durations', locale: :en)])
    end

    it 'refuses a booking without a duration, writing nothing' do
      expect { book(description: 'x') }.not_to(change { bookings })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include('error' => 'validation_failed', 'code' => 'invalid_input')
      expect(body['errors']).to eq([I18n.t('services.time_session_booking.duration_missing', locale: :en)])
    end

    { duration_string: '24:01', duration_minutes: 1441 }.each do |key, too_long|
      it "refuses more than a day (#{key} #{too_long}), writing nothing" do
        expect { book(key => too_long) }.not_to(change { bookings })
        expect(response).to have_http_status(:unprocessable_content)
        expect(body).to include('error' => 'validation_failed', 'code' => 'invalid_input')
      end
    end

    it 'refuses minutes that are no whole number instead of cutting them, writing nothing' do
      expect { book(duration_minutes: '1.5') }.not_to(change { bookings })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to eq('error' => 'validation_failed', 'code' => 'invalid_input',
                         'errors' => [I18n.t('services.time_session_booking.duration_minutes_invalid', locale: :en)])
    end

    it 'refuses minutes that are no number at all as input, not as a crash' do
      post "/api/v1/tickets/#{ticket.id}/time_sessions",
           params: { time_session: { duration_minutes: true } }.to_json,
           headers: { 'Authorization' => "Bearer #{pat.token}", 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include('error' => 'validation_failed', 'code' => 'invalid_input')
    end

    it 'answers the refusal in the token owner language' do
      user.update!(language_preference: 'de')
      book(duration_string: '1:30', duration_minutes: 45)
      expect(body['errors']).to eq([I18n.t('services.time_session_booking.both_durations', locale: :de)])
    end
  end

  describe 'the day (a calendar day in the profile zone, stored as midnight)' do
    it 'defaults to today in the profile zone, also right after midnight there' do
      travel_to Time.utc(2026, 8, 19, 22, 30) do # 00:30 on Aug 20 in Berlin
        book(duration_minutes: 30)
      end
      expect(response).to have_http_status(:created)
      expect(booked.occurred_on).to eq(Time.zone.parse('2026-08-20 00:00'))
      expect(body.dig('data', 'occurred_on')).to eq(Time.zone.parse('2026-08-20 00:00').iso8601)
    end

    it 'takes the day a timestamp falls on in the profile zone' do
      book(duration_minutes: 30, occurred_on: '2026-08-20T00:30:00+02:00')
      expect(booked.occurred_on).to eq(Time.zone.parse('2026-08-20 00:00'))
      book(duration_minutes: 30, occurred_on: '2026-05-20T10:00:00Z')
      expect(booked.occurred_on).to eq(Time.zone.parse('2026-05-20 00:00'))
    end

    it 'takes a plain date as that day' do
      book(duration_minutes: 30, occurred_on: '2026-08-20')
      expect(booked.occurred_on).to eq(Time.zone.parse('2026-08-20 00:00'))
    end

    it 'takes a plain date as that day in a zone west of UTC too' do
      user.update!(timezone: 'America/New_York')
      book(duration_minutes: 30, occurred_on: '2026-08-20')
      expect(booked.occurred_on).to eq(Time.zone.parse('2026-08-20 00:00'))
    end

    %w[gestern 05.01.2026 2026-02-30].push('2026-10-29 10:00').each do |raw|
      it "refuses the unreadable date #{raw.inspect} instead of booking now, writing nothing" do
        expect { book(duration_minutes: 30, occurred_on: raw) }.not_to(change { bookings })
        expect(response).to have_http_status(:unprocessable_content)
        expect(body).to eq('error' => 'validation_failed', 'code' => 'invalid_input',
                           'errors' => [I18n.t('services.time_session_booking.occurred_on_invalid', locale: :en)])
      end
    end
  end

  it 'writes through Actors::SaveTimeSession' do
    expect(Actors::SaveTimeSession).to receive(:call).and_call_original
    book(duration_minutes: 30)
    expect(response).to have_http_status(:created)
  end

  it 'answers an actor refusal with its code, writing nothing' do
    allow(Actors::SaveTimeSession).to receive(:call)
      .and_return(Actors::BaseActor::Result.new(success: false, errors: ['nope'], code: :group_billed))
    book(duration_minutes: 30)
    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to eq('error' => 'group_billed', 'code' => 'refused', 'reason' => 'group_billed', 'errors' => ['nope'])
  end

  # A failure the server did not expect (BaseActor's :internal_error in
  # production, where it does not re-raise) is no refusal of the input: a 500
  # without the exception's text, so a client may retry and learns nothing of
  # the database.
  it 'answers an unexpected actor failure as a server error without its text' do
    allow(Actors::SaveTimeSession).to receive(:call)
      .and_return(Actors::BaseActor::Result.new(success: false, errors: ['PG::Error: secret'], code: :internal_error))
    book(duration_minutes: 30)
    expect(response).to have_http_status(:internal_server_error)
    expect(response.body).not_to include('secret')
    expect(body).to include('error' => 'internal_error')
  end

  it 'books the same row the MCP tool books for the same input' do
    input = { duration_string: '1:30', occurred_on: '2026-08-20T00:30:00+02:00', description: 'Fixed the login' }
    book(**input)
    rest = booked

    context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project,
                                           authorization: Lalabase::Tools::AuthorizationRecorder.new)
    mcp_args = { ticket_id: ticket.id, duration: input[:duration_string], occurred_on: input[:occurred_on],
                 description: input[:description] }
    mcp = ActsAsTenant.with_tenant(organisation) do
      TimeSession.find(JSON.parse(Lalabase::Tools::CreateTimeSession.execute(args: mcp_args, context: context).content)['id'])
    end

    fields = %i[occurred_on duration description customer_description creator_id ticket_id project_id organisation_id]
    expect(mcp.slice(*fields)).to eq(rest.slice(*fields))
  end

  # What a client reloads after a booking (cli_rest_plan K6): the booking is no
  # activity and notifies nobody; it touches the ticket's updated_at.
  it 'writes no activity and no notification, and touches the ticket' do
    ActsAsTenant.with_tenant(organisation) { ticket.update_column(:updated_at, 1.day.ago) }
    expect { book(duration_minutes: 30) }
      .not_to(change { ActsAsTenant.without_tenant { [Activity.count, Notification.count] } })
    expect(response).to have_http_status(:created)
    expect(ActsAsTenant.without_tenant { ticket.reload.updated_at }).to be > 1.minute.ago
  end

  describe 'who may book' do
    it 'answers a missing and a hidden ticket the same, writing nothing' do
      book(ticket_id: SecureRandom.uuid, duration_minutes: 30)
      missing = [response.status, response.body]

      ActsAsTenant.with_tenant(organisation) { ProjectPermission.where(user: user, project: project).destroy_all }
      expect { book(duration_minutes: 30) }.not_to(change { bookings })
      expect([response.status, response.body]).to eq(missing)
      expect(missing.first).to eq(404)
    end

    # The input is checked inside the read gate: a refusal of the input only for
    # a ticket the token can read, so it tells nothing the 404 does not.
    it 'answers a hidden ticket with unusable input like a missing one' do
      book(ticket_id: SecureRandom.uuid, duration_string: '1:30', duration_minutes: 45)
      missing = [response.status, response.body]
      ActsAsTenant.with_tenant(organisation) { ProjectPermission.where(user: user, project: project).destroy_all }
      book(duration_string: '1:30', duration_minutes: 45)
      expect([response.status, response.body]).to eq(missing)
    end

    it 'refuses a booking without the time permission in the project, writing nothing' do
      ActsAsTenant.with_tenant(organisation) { TimeSessionPermission.where(user: user).destroy_all }
      expect { book(duration_minutes: 30) }.not_to(change { bookings })
      expect(response).to have_http_status(:forbidden)
      expect(body).to include('error' => 'forbidden', 'code' => 'forbidden')
    end

    context 'with a read-only token' do
      let(:read_only) { true }

      it 'refuses, writing nothing' do
        expect { book(duration_minutes: 30) }.not_to(change { bookings })
        expect(response).to have_http_status(:forbidden)
        expect(body).to eq('error' => 'forbidden', 'code' => 'read_only')
      end
    end
  end
end

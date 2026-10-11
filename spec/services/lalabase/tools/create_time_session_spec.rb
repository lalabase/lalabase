# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::CreateTimeSession, the MCP time booking (inbox workflow S2).
# Type: Service spec.
# Why:  A booking is money. Three things must hold: (1) the write goes through
#       Actors::SaveTimeSession with the actor as creator, never a raw save;
#       (2) both authorizations run before the write (ticket :show?, session
#       :create? = the project's time permission) and mark the D7 decision;
#       (3) unusable input (no duration, prose duration, a bad occurred_on, a
#       ticket outside the project) is refused before anything is written.
RSpec.describe Lalabase::Tools::CreateTimeSession do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }

  let(:actor) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end
  # A colleague created the ticket: a booking on the ticket's creator instead of
  # the actor would put money on the wrong person and look identical otherwise.
  let(:colleague) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: colleague) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) do
    Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project, authorization: recorder)
  end
  let(:time_permission) { create(:time_session_permission, user: actor, project: project, can_create_own: true) }

  # The tenant first: every fixture below is tenant-scoped (a let! above this
  # hook would run before it and raise NoTenantSet).
  before do
    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: actor, project: project, tickets_access: :read_write)
    time_permission
  end
  after { ActsAsTenant.current_tenant = nil }

  def run(args)
    described_class.execute(args: { ticket_id: ticket.id }.merge(args), context: context)
  end

  describe 'contract metadata' do
    it 'is a project-scoped, mutating, record-mode tool that requires the actor' do
      expect(described_class.scope_mode).to eq(:project)
      expect(described_class.mutating?).to be true
      expect(described_class.requires_actor?).to be true
      expect(described_class.authorization_mode).to eq(:record)
    end
  end

  it 'books time with a duration string through the actor, as the actor, and answers the API row' do
    result = nil
    expect { result = run(duration: '1:30', description: 'Fehler eingegrenzt') }.to change(TimeSession, :count).by(1)
    expect(result.success?).to be true
    payload = JSON.parse(result.content)
    expect(payload).to include('ticket_id' => ticket.id, 'duration_minutes' => 90,
                               'description' => 'Fehler eingegrenzt', 'billed' => false)
    expect(payload.dig('creator', 'id')).to eq(actor.id)
    expect(recorder.authorized?).to be true

    booked = TimeSession.find(payload['id'])
    expect(booked.creator).to eq(actor)
    expect(booked.ticket).to eq(ticket)
    expect(booked.project).to eq(project)
    expect(booked.occurred_on).to eq(actor.time_zone.today.in_time_zone)
  end

  # occurred_on is a DATE for billing (the form stores midnight of the picked
  # day, every report buckets by that day). The actor's calendar runs in the
  # profile zone (Europe/Berlin by default), the app zone is UTC: a call at
  # 00:30 Berlin belongs to that Berlin day, not to the UTC day before.
  describe 'the booking date' do
    include ActiveSupport::Testing::TimeHelpers

    it 'defaults to today in the actor zone, stored as midnight like the form' do
      travel_to Time.utc(2026, 8, 31, 22, 30) do
        payload = JSON.parse(run(duration: '30').content)
        expect(TimeSession.find(payload['id']).occurred_on).to eq(Time.zone.parse('2026-09-01 00:00:00'))
      end
    end

    it 'reads a timestamp as the date it falls on in the actor zone and drops the time of day' do
      payload = JSON.parse(run(duration: '30', occurred_on: '2026-09-01T00:30:00+02:00').content)
      expect(payload['occurred_on']).to eq(Time.zone.parse('2026-09-01 00:00:00').iso8601)
      late = JSON.parse(run(duration: '30', occurred_on: '2026-08-31T22:30:00Z').content)
      expect(late['occurred_on']).to eq(Time.zone.parse('2026-09-01 00:00:00').iso8601)
    end

    it 'takes a plain date as that date' do
      payload = JSON.parse(run(duration: '30', occurred_on: '2026-08-20').content)
      expect(payload['occurred_on']).to eq(Time.zone.parse('2026-08-20 00:00:00').iso8601)
    end

    it 'follows the actor profile zone, not a fixed one' do
      actor.update!(timezone: 'Pacific/Auckland')
      payload = JSON.parse(run(duration: '30', occurred_on: '2026-08-31T13:00:00Z').content)
      expect(payload['occurred_on']).to eq(Time.zone.parse('2026-09-01 00:00:00').iso8601)
    end

    it 'refuses an offset no clock has instead of reading the time as UTC, writing nothing' do
      expect { expect(run(duration: '30', occurred_on: '2026-08-20T10:00+99:99').error).to match(/occurred_on/) }
        .not_to change(TimeSession, :count)
    end
  end

  it 'refuses a booking longer than a day as a booking error, writing nothing' do
    expect { expect(run(duration: '99999999999:00').error).to match(/booking failed/) }
      .not_to change(TimeSession, :count)
    expect { expect(run(duration_minutes: TimeSession::MAX_DURATION_MINUTES + 1).error).to match(/booking failed/) }
      .not_to change(TimeSession, :count)
  end

  it 'books as the actor, never as the ticket creator' do
    payload = JSON.parse(run(duration: '30').content)
    expect(payload.dig('creator', 'id')).to eq(actor.id)
    expect(TimeSession.find(payload['id']).creator).to eq(actor)
  end

  it 'keeps the customer description' do
    payload = JSON.parse(run(duration: '30', customer_description: 'Fuer den Kunden').content)
    expect(payload['customer_description']).to eq('Fuer den Kunden')
  end

  it 'refuses an occurred_on the calendar or the database cannot hold, writing nothing' do
    expect do
      expect(run(duration: '30', occurred_on: '2026-02-30').error).to match(/occurred_on/)
      expect(run(duration: '30', occurred_on: '99999-01-01').error).to match(/occurred_on/)
    end.not_to change(TimeSession, :count)
  end

  it 'takes duration_minutes and an explicit occurred_on' do
    payload = JSON.parse(run(duration_minutes: 45, occurred_on: '2026-08-20T10:00:00Z').content)
    expect(payload['duration_minutes']).to eq(45)
    expect(payload['occurred_on']).to eq(Time.zone.parse('2026-08-20 00:00:00').iso8601)
  end

  it 'refuses duration and duration_minutes together instead of letting one win, writing nothing' do
    result = nil
    expect { result = run(duration: '1:30', duration_minutes: 45) }.not_to change(TimeSession, :count)
    expect(result.error).to match(/not both/)
  end

  it 'refuses a call without any duration, writing nothing' do
    result = nil
    expect { result = run({}) }.not_to change(TimeSession, :count)
    expect(result.error).to match(/duration/)
  end

  it 'passes an unusable duration back as a booking error (prose, zero minutes), writing nothing' do
    expect { expect(run(duration: 'eine Stunde').error).to match(/booking failed/) }
      .not_to change(TimeSession, :count)
    expect { expect(run(duration_minutes: 0).error).to match(/booking failed/) }
      .not_to change(TimeSession, :count)
  end

  it 'refuses an unusable occurred_on before touching the ticket' do
    expect(run(duration: '30', occurred_on: 'gestern').error).to match(/occurred_on/)
  end

  it 'rejects a malformed ticket_id without hitting the database' do
    expect(run(ticket_id: '42', duration: '30').error).to eq('invalid ticket_id format')
  end

  it 'answers an empty result for a ticket outside the project, never a foreign booking' do
    other_project = create(:project, organisation: organisation)
    # Every right granted over there, so the project boundary is the ONLY reason.
    create(:project_permission, user: actor, project: other_project, tickets_access: :read_write)
    create(:time_session_permission, user: actor, project: other_project, can_create_own: true)
    other_ticket = create(:ticket, project: other_project, organisation: organisation, creator: actor)
    result = nil
    expect { result = run(ticket_id: other_ticket.id, duration: '30') }.not_to change(TimeSession, :count)
    expect(result.empty?).to be true
  end

  # The time permission alone must not book on a ticket the actor may not read,
  # and the answer must not confirm that the ticket exists: it is looked up
  # inside the read scope (Base.readable_tickets) and answers like a missing one.
  it 'answers a ticket without read access like a missing one, even with the time permission, writing nothing' do
    ProjectPermission.where(user: actor, project: project).destroy_all
    result = run(duration: '30')
    expect(result.empty?).to be true
    expect(result.content).to eq("No ticket found for #{ticket.id}.")
    expect(TimeSession.count).to eq(0)
  end

  it 'raises the per-record denial without the project time permission, writing nothing' do
    time_permission.destroy
    expect { run(duration: '30') }.to raise_error(Pundit::NotAuthorizedError)
    expect(TimeSession.count).to eq(0)
  end
end

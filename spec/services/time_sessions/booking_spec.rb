# frozen_string_literal: true

require 'rails_helper'

# What: TimeSessions::Booking, the one rule of a time booking through a token.
# Type: Service spec.
# Why:  The MCP tool create_time_session and POST /api/v1/tickets/:id/time_sessions
#       both book through it (cli_rest_plan R6, D5). A booking is money: the day it
#       lands on decides the invoice, one duration must never silently win over the
#       other, and the write must go through Actors::SaveTimeSession (billed guards,
#       one transaction), never a raw save.
RSpec.describe TimeSessions::Booking do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:actor)        { create(:user, timezone: 'Europe/Berlin') }
  let(:ticket)       { create(:ticket, project: project, organisation: organisation, creator: create(:user)) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def parse(**input)
    described_class.parse(actor: actor, **input)
  end

  describe 'refusals' do
    it 'refuses a booking without a duration' do
      expect(parse.refusal).to eq(:duration_missing)
      expect(parse(duration_string: '  ').refusal).to eq(:duration_missing)
      expect(parse(duration_minutes: '').refusal).to eq(:duration_missing)
    end

    it 'refuses both durations instead of letting one win' do
      expect(parse(duration_string: '1:30', duration_minutes: 45).refusal).to eq(:both_durations)
      expect(parse(duration_string: '1:30', duration_minutes: '45').refusal).to eq(:both_durations)
    end

    # Minutes are a whole number: a fraction would be cut to the minute below
    # ("1.5" booked as 1, while duration_string "1.5" is 90), and a value
    # that is no number at all must not reach the model as a crash.
    it 'refuses minutes that are no whole number' do
      [1.5, '1.5', true, false, '1e2', [30], { a: 1 }].each do |minutes|
        expect(parse(duration_minutes: minutes).refusal).to eq(:duration_minutes_invalid), minutes.inspect
      end
    end

    it 'takes whole minutes as a number or as digits' do
      [45, '45', ' 45 ', '+45', 0, -5, '-5'].each do |minutes|
        expect(parse(duration_minutes: minutes).refused?).to be(false), minutes.inspect
      end
    end

    it 'refuses an occurred_on it cannot read' do
      %w[gestern 05.01.2026 2026-02-30 10000-01-01].push('2026-10-29 10:00').each do |raw|
        expect(parse(duration_string: '30', occurred_on: raw).refusal).to eq(:occurred_on_invalid), raw
      end
    end

    it 'checks the duration before the date' do
      expect(parse(occurred_on: 'gestern').refusal).to eq(:duration_missing)
    end

    it 'accepts a usable input' do
      booking = parse(duration_string: '30')
      expect(booking.refused?).to be false
      expect(booking.refusal).to be_nil
    end
  end

  describe 'the booking date (a calendar day in the actor zone, stored as midnight)' do
    def day_of(**input)
      parse(duration_string: '30', **input).build(ticket: ticket).occurred_on
    end

    it 'defaults to today in the actor zone, also right after midnight there' do
      travel_to Time.utc(2026, 8, 19, 22, 30) do # 00:30 on Aug 20 in Berlin
        expect(day_of).to eq(Time.zone.parse('2026-08-20 00:00'))
      end
    end

    it 'takes the day a timestamp falls on in the actor zone' do
      expect(day_of(occurred_on: '2026-08-20T00:30:00+02:00')).to eq(Time.zone.parse('2026-08-20 00:00'))
      expect(day_of(occurred_on: '2026-08-19T22:30:00Z')).to eq(Time.zone.parse('2026-08-20 00:00'))
      expect(day_of(occurred_on: '2026-08-19T21:59:00Z')).to eq(Time.zone.parse('2026-08-19 00:00'))
    end

    it 'reads a timestamp without an offset as UTC' do
      expect(day_of(occurred_on: '2026-08-19T22:30:00')).to eq(Time.zone.parse('2026-08-20 00:00'))
    end

    it 'takes a plain date as that day' do
      expect(day_of(occurred_on: '2026-08-20')).to eq(Time.zone.parse('2026-08-20 00:00'))
    end

    it 'follows the actor profile zone' do
      actor.update!(timezone: 'America/New_York')
      expect(day_of(occurred_on: '2026-08-20T02:00:00Z')).to eq(Time.zone.parse('2026-08-19 00:00'))
    end

    # A plain date names the day itself. Read as UTC midnight and then moved into
    # a zone west of UTC, it would land on the day before.
    it 'takes a plain date as that day in a zone west of UTC too' do
      actor.update!(timezone: 'America/New_York')
      expect(day_of(occurred_on: '2026-08-20')).to eq(Time.zone.parse('2026-08-20 00:00'))
    end
  end

  describe '#build' do
    it 'builds an unsaved booking on the ticket, as the actor' do
      session = parse(duration_string: '1:30', description: 'Fixed it', customer_description: 'Login')
                .build(ticket: ticket)
      expect(session).to be_new_record
      expect(session).to have_attributes(ticket: ticket, project: project, organisation: organisation,
                                         creator: actor, description: 'Fixed it', customer_description: 'Login')
    end

    it 'takes the duration as text or as minutes' do
      { { duration_string: '30' } => 30, { duration_string: '1:30' } => 90, { duration_string: '1.5' } => 90,
        { duration_minutes: 45 } => 45, { duration_minutes: '45' } => 45 }.each do |input, minutes|
        session = parse(**input).build(ticket: ticket)
        session.valid?
        expect(session.duration).to eq(minutes), input.inspect
      end
    end

    it 'stores blank descriptions as none' do
      session = parse(duration_string: '30', description: '', customer_description: ' ').build(ticket: ticket)
      expect(session.description).to be_nil
      expect(session.customer_description).to be_nil
    end
  end

  describe '#save' do
    it 'writes through Actors::SaveTimeSession, without a group change' do
      booking = parse(duration_string: '30')
      session = booking.build(ticket: ticket)
      expect(Actors::SaveTimeSession).to receive(:call)
        .with(time_session: session, attributes: {}, group_change: { requested: false, group: nil },
              current_user: actor).and_call_original
      result = booking.save(session)
      expect(result.success?).to be true
      expect(result.resource).to be_persisted
    end

    it 'answers the model refusal for a duration over a day, writing nothing' do
      booking = parse(duration_string: '24:01')
      result = nil
      expect { result = booking.save(booking.build(ticket: ticket)) }.not_to change(TimeSession, :count)
      expect(result.success?).to be false
      expect(result.code).to eq(:validation_failed)
    end

    it 'books a full day' do
      booking = parse(duration_string: '24:00')
      expect(booking.save(booking.build(ticket: ticket)).success?).to be true
    end
  end
end

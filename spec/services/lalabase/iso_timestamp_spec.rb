# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::IsoTimestamp, the one owner of "is this a storable ISO 8601 timestamp".
# Type: Service spec.
# Why:  Two surfaces hand a typed timestamp to PostgreSQL (the inbox `since`
#       bound, the time booking's occurred_on). The four-digit-year check runs
#       BEFORE the parse on purpose; the sibling TimeSessions::DateBound shows
#       what a parser alone lets through.
RSpec.describe Lalabase::IsoTimestamp do
  it 'parses a date, a date with time, seconds, a fraction, Z and an offset' do
    expect(described_class.parse('2026-08-20')).to eq(Time.zone.parse('2026-08-20 00:00:00'))
    expect(described_class.parse('2026-08-20T10:30')).to eq(Time.zone.parse('2026-08-20 10:30:00'))
    expect(described_class.parse('2026-08-20T10:30:15')).to eq(Time.zone.parse('2026-08-20 10:30:15'))
    expect(described_class.parse('2026-08-20T10:30:15.5Z')).to eq(Time.utc(2026, 8, 20, 10, 30, 15.5))
    expect(described_class.parse('2026-08-20T12:30:15+02:00')).to eq(Time.utc(2026, 8, 20, 10, 30, 15))
  end

  it 'answers nil for a five-digit year, an impossible date, prose, a space, or nothing' do
    ['99999-01-01', '2026-13-01', '2026-02-30', 'gestern', '2026-08-20 10:00', '', nil].each do |bad|
      expect(described_class.parse(bad)).to be_nil, bad.inspect
    end
  end

  it 'tolerates surrounding whitespace' do
    expect(described_class.parse('  2026-08-20T10:30:00Z ')).to eq(Time.utc(2026, 8, 20, 10, 30))
  end

  # Date._iso8601 answers offset nil for these and Time.zone.iso8601 would then
  # read the string as zone-less: a refused parse, never a silently shifted instant.
  it 'refuses an offset no clock has, instead of reading the time as UTC' do
    ['2026-08-20T10:00+99:99', '2026-08-20T10:00+24:00', '2026-08-20T10:00+02:60', '2026-08-20T10:00+2:00'].each do |bad|
      expect(described_class.parse(bad)).to be_nil, bad
    end
    expect(described_class.parse('2026-08-20T10:00+0200')).to eq(Time.utc(2026, 8, 20, 8))
    expect(described_class.parse('2026-08-20T10:00-23:59')).to eq(Time.utc(2026, 8, 21, 9, 59))
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The counter behind "this address already has an account". The doors are held
# by spec/requests/auth_throttle_spec.rb (the form) and
# spec/requests/api/provisioning/throttle_spec.rb (the website).
RSpec.describe Signups::TakenAddressBrake do
  include ActiveSupport::Testing::TimeHelpers

  # Rack::Attack counts into a null store in test; one window of the counter,
  # whenever the suite runs.
  around do |example|
    store_was = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    travel_to(Time.current) { example.run }
  ensure
    Rack::Attack.cache.store = store_was
  end

  let(:address) { '203.0.113.9' }

  it 'closes on the answer that reaches the limit, not before' do
    (described_class::LIMIT - 1).times { described_class.record(address) }
    expect(described_class.banned?(address)).to be(false)

    described_class.record(address)
    expect(described_class.banned?(address)).to be(true)
  end

  it 'keeps one bucket per address' do
    described_class::LIMIT.times { described_class.record(address) }

    expect(described_class.banned?('203.0.113.10')).to be(false)
  end

  it 'stays closed for the period and opens after it' do
    described_class::LIMIT.times { described_class.record(address) }

    travel(described_class::PERIOD - 1.minute)
    expect(described_class.banned?(address)).to be(true)

    travel(2.minutes)
    expect(described_class.banned?(address)).to be(false)
  end

  # The form passes the address as the request spells it, the provisioning
  # endpoint as IPAddr prints it.
  it 'takes two spellings of one IPv6 address for one address' do
    described_class::LIMIT.times { described_class.record('2001:DB8:0:0:0:0:0:1') }

    expect(described_class.banned?('2001:db8::1')).to be(true)
  end

  it 'blocks the IPv4-mapped spelling of a banned IPv4 address' do
    described_class::LIMIT.times { described_class.record(address) }

    expect(described_class.banned?("::ffff:#{address}")).to be(true)
  end

  # nil is what the provisioning endpoint passes when the website named no
  # visitor. A shared bucket for "nobody" would close the sign-up for all of them.
  [nil, '', 'not-an-address'].each do |nobody|
    it "counts nothing and closes nothing for #{nobody.inspect}" do
      (described_class::LIMIT + 1).times { described_class.record(nobody) }

      expect(described_class.banned?(nobody)).to be(false)
    end
  end
end

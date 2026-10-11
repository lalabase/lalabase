# frozen_string_literal: true

require 'rails_helper'

# The ONE owner of "several sessions, one word for the subject". It exists so the
# hours chip in the ticket header and the billing column of the ticket table
# cannot answer that question differently. What is pinned here is therefore the
# fold itself: every bucket maps somewhere, and more than one filled bucket is
# :mixed, never a winner.
RSpec.describe TimeSessions::SubjectBillingStatus do
  def status(counts)
    described_class.call(counts: counts)
  end

  describe 'a single filled bucket' do
    # Iterating the CONSTANT, not a literal list: a bucket added to
    # TimeSession::BILLING_STATUS_FILTERS without an answer fails here.
    TimeSession::BILLING_STATUS_FILTERS.each do |bucket|
      it "answers #{bucket} by its own name" do
        expect(status(bucket => 1)).to eq(bucket.to_sym)
      end
    end

    # The point of S1: a subject-level answer is a bucket, not a translation of
    # one. This used to be :open where the bucket says 'without_billing', and the
    # rename is only real if the word is there under the new key.
    it 'answers with the bucket name the locales are keyed on' do
      expect(status('without_billing' => 3)).to eq(:without_billing)
      expect(I18n.t('views.time_sessions.billing_status.without_billing',
                    locale: :de, fallback: false)).to be_present
    end

    it 'has no word left under the retired :open key' do
      %i[de en].each do |locale|
        expect(I18n.exists?('views.time_sessions.billing_status.open', locale, fallback: false)).to be(false)
      end
    end
  end

  describe 'no sessions at all' do
    it 'is :no_sessions for an empty hash' do
      expect(status({})).to eq(:no_sessions)
    end

    it 'is :no_sessions when every bucket is present but zero' do
      expect(status(TimeSession::BILLING_STATUS_FILTERS.index_with { 0 })).to eq(:no_sessions)
    end

    it 'is :no_sessions for nil counts, not a crash' do
      expect(status('billed' => nil)).to eq(:no_sessions)
    end
  end

  # The boundary that matters: one filled bucket names itself, two are :mixed.
  # n-1 / n / n+1 around "more than one".
  describe 'the boundary between one bucket and several' do
    it 'names the bucket when exactly one is filled' do
      expect(status('billed' => 2, 'in_billing' => 0, 'without_billing' => 0)).to eq(:billed)
    end

    it 'is :mixed as soon as a second bucket has a session' do
      expect(status('billed' => 2, 'in_billing' => 1)).to eq(:mixed)
    end

    it 'is :mixed with all three filled' do
      expect(status(TimeSession::BILLING_STATUS_FILTERS.index_with { 1 })).to eq(:mixed)
    end

    it 'is :mixed even when one bucket dwarfs the other (no majority winner)' do
      expect(status('billed' => 999, 'without_billing' => 1)).to eq(:mixed)
    end
  end

  describe 'every two-bucket pair' do
    TimeSession::BILLING_STATUS_FILTERS.combination(2).each do |a, b|
      it "is :mixed for #{a} + #{b}" do
        expect(status(a => 1, b => 1)).to eq(:mixed)
      end
    end
  end

  # The number lives beside the fold because it answers the same question at a
  # finer resolution. Read by the time list and by the ticket table's billing
  # column, which must not each round it their own way.
  describe '.percent_billed' do
    def percent(billed: 0, in_billing: 0, without_billing: 0)
      described_class.percent_billed(
        minutes: { 'billed' => billed, 'in_billing' => in_billing, 'without_billing' => without_billing }
      )
    end

    it 'is nil when nothing is invoiced, so a caller has nothing to print' do
      expect(percent(in_billing: 60, without_billing: 60)).to be_nil
    end

    it 'is nil when nothing is booked at all' do
      expect(percent).to be_nil
      expect(described_class.percent_billed(minutes: {})).to be_nil
    end

    # n-1 / n / n+1 around the rounding. The WORD stays mixed at both ends: 999
    # of 1000 rounds to 100 and 1 of 1000 rounds to 0, and neither is the whole
    # story, which is why the fold above never reads this number.
    it 'rounds rather than truncates at both ends' do
      expect(percent(billed: 1, without_billing: 999)).to eq(0)
      expect(percent(billed: 500, without_billing: 500)).to eq(50)
      expect(percent(billed: 999, without_billing: 1)).to eq(100)
    end

    it 'is 100 when everything is invoiced' do
      expect(percent(billed: 60)).to eq(100)
    end

    it 'counts against every bucket, not only against the loose one' do
      expect(percent(billed: 30, in_billing: 30, without_billing: 60)).to eq(25)
    end
  end
end

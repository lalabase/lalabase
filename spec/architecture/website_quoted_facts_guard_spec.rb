# frozen_string_literal: true

require 'rails_helper'

# What: the values lalabase.com quotes FROM this code still say what this code does.
# Why:  the public pages left the core (website split, W3). Four of them state a fact
#   about the core rather than about themselves -- the privacy policy names two retention
#   periods and a deletion window, the sign-up form offers the revenue bands the core
#   validates, a feature chapter shows the default documentation path. While those views
#   lived here they read the constants; across two repositories they are a COPY, in
#   CoreFacts (app/models/core_facts.rb) of gboyke/lalabase-website.
#
#   A copy of a retention period is a promise someone else keeps. Change
#   `confirm_within` to three days and the website still tells visitors seven, in a
#   document that is legally binding -- and nothing anywhere goes red.
#
# What this guard can and cannot do: it cannot read the other repository, so it does not
#   verify that the website is right. It refuses to let THIS side move in silence. A red
#   run means: the change is fine, and now the website has to follow it.
#
# The counterpart on the website side is the comment in CoreFacts itself. The stronger
# version -- the core publishing these facts on its public API so the website checks them
# at deploy time instead of copying them -- is deliberately not built yet: a privacy page
# has to render the same numbers whether or not the core is reachable.
# quoted: what CoreFacts on the website says today.
# actual: where this code says it, read at run time.
#
# A local rather than a constant: RSpec builds the examples from it while the describe
# block is being read, and a constant defined in there leaks into Object.
facts = [
  { name: 'CONFIRMATION_LINK_VALID_FOR',
    quoted: 7.days,
    actual: -> { Devise.confirm_within },
    source: 'config/initializers/devise.rb (config.confirm_within)',
    quoted_on: 'the privacy policy, and the note after a sign-up' },
  { name: 'UNCONFIRMED_ACCOUNT_RETENTION',
    quoted: 14.days,
    actual: -> { UnconfirmedSignupPurgeJob::RETENTION },
    source: 'UnconfirmedSignupPurgeJob::RETENTION',
    quoted_on: 'the privacy policy (how long an unconfirmed account is kept)' },
  { name: 'ACQUISITION_RETENTION',
    quoted: 12.months,
    actual: -> { AcquisitionSource::RETENTION },
    source: 'AcquisitionSource::RETENTION',
    quoted_on: 'the privacy policy (how long the acquisition answer is kept)' },
  { name: 'FOUNDER_REVENUE_BANDS',
    quoted: %w[up_to_50k 50k_to_250k 250k_to_1m above_1m],
    actual: -> { FounderSignup::REVENUE_BANDS },
    source: 'FounderSignup::REVENUE_BANDS',
    quoted_on: 'the sign-up form (the bands it offers; this side validates them)' },
  { name: 'DOCUMENTATION_PATH_PREFIX',
    quoted: '.lalabase/doku/',
    actual: -> { DocumentationSet.columns_hash['path_prefix'].default },
    source: 'the documentation_sets.path_prefix column default',
    quoted_on: 'the documentation feature chapter' }
].freeze

RSpec.describe 'Facts the public website quotes from this code' do
  facts.each do |fact|
    it "still holds #{fact[:name]}" do
      expect(fact[:actual].call).to eq(fact[:quoted]), <<~MESSAGE
        #{fact[:source]} is now #{fact[:actual].call.inspect}, but lalabase.com quotes
        #{fact[:quoted].inspect} on #{fact[:quoted_on]}.

        Change CoreFacts::#{fact[:name]} in gboyke/lalabase-website
        (app/models/core_facts.rb) to match, then update the number here.
      MESSAGE
    end
  end

  # Without this, a fact could be dropped from the table and nobody would notice that the
  # website still quotes it.
  it 'covers every value CoreFacts carries' do
    expect(facts.map { |fact| fact[:name] }).to contain_exactly(
      'CONFIRMATION_LINK_VALID_FOR', 'UNCONFIRMED_ACCOUNT_RETENTION', 'ACQUISITION_RETENTION',
      'FOUNDER_REVENUE_BANDS', 'DOCUMENTATION_PATH_PREFIX'
    )
  end
end

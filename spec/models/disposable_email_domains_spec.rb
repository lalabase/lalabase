# frozen_string_literal: true

require 'rails_helper'

# The curated throw-away list is hand-maintained and governs exactly one path:
# self-service sign-up. A fat-fingered or over-broad entry (a mainstream
# provider, a customer's own domain) silently rejects real sign-ups, and the
# subdomain rule widens the blast radius of one wrong short entry to everything
# under it. These guards fail loudly instead.
RSpec.describe DisposableEmailDomains do
  describe '.all' do
    it 'is not empty (a broken or empty file would disable the filter)' do
      expect(described_class.all).not_to be_empty
    end

    # The one addition that would quietly break real sign-ups: a mainstream
    # mailbox provider landing on the list.
    it 'lists no mainstream mailbox provider' do
      %w[gmail.com googlemail.com outlook.com hotmail.com web.de gmx.de gmx.net
         t-online.de icloud.com yahoo.com yahoo.de proton.me protonmail.com].each do |provider|
        expect(described_class.match?("someone@#{provider}")).to be(false), "#{provider} is on the throw-away list"
      end
    end

    # Every entry must be a bare domain: a dot, no @, no whitespace. A stray
    # "@" or space means the entry matches nothing and rots silently.
    it 'holds only well-formed bare domains' do
      entries = described_class.all.to_a
      entries.each do |entry|
        expect(entry).to include('.'), "#{entry.inspect} has no dot"
        expect(entry).not_to include('@'), "#{entry.inspect} contains @"
        expect(entry).not_to match(/\s/), "#{entry.inspect} contains whitespace"
      end
    end
  end

  # load_domains is fail-open on purpose (the filter is one defence among
  # several) but must never raise on the public sign-up path, and must be loud.
  describe 'resilience of the loader' do
    it 'returns an empty, non-raising set and warns when the file is empty' do
      allow(YAML).to receive(:safe_load_file).and_return(nil)
      expect(Rails.logger).to receive(:warn).with(/effectively disabled/)

      expect(described_class.send(:load_domains)).to eq(Set.new)
    end

    it 'returns an empty, non-raising set and logs when the file is malformed' do
      allow(YAML).to receive(:safe_load_file).and_raise(StandardError, 'broken yaml')
      expect(Rails.logger).to receive(:error).with(/could not load/)

      expect { described_class.send(:load_domains) }.not_to raise_error
    end
  end
end

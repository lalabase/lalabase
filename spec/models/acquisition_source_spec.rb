# frozen_string_literal: true

require 'rails_helper'

# What: the value object that owns what an acquisition record contains
#       (doc/akquise_herkunft.md).
# Type: Unit spec -- it takes a request and returns a hash, no database needed.
# Why:  Three rules live here and nowhere else, and each one is silently
#       breakable: the channel PRIORITY (a hand-issued ref must beat a campaign
#       parameter), the referrer reduced to a FOREIGN host only, and the fact
#       that a visit declaring nothing at all still produces a row -- dropping
#       those would leave an evaluation that only ever sees campaign traffic.
RSpec.describe AcquisitionSource do
  def request_double(path: '/features', params: {}, referer: nil, host: 'lalabase.com')
    instance_double(ActionDispatch::Request,
                    path: path, query_parameters: params.stringify_keys,
                    referer: referer, host: host)
  end

  describe '.from_request' do
    it 'keeps the declared parameters and the landing path' do
      source = described_class.from_request(
        request_double(path: '/pricing', params: { ref: 'redmine-mail-01', utm_source: 'linkedin' })
      )

      expect(source.to_h).to include(
        'ref' => 'redmine-mail-01', 'utm_source' => 'linkedin', 'landing_path' => '/pricing'
      )
      expect(source.first_seen_at).to be_within(5.seconds).of(Time.current)
    end

    it 'records a visit that declares nothing, because the entry page is the answer' do
      source = described_class.from_request(request_double(path: '/features'))

      expect(source).not_to be_nil
      expect(source.landing_path).to eq('/features')
      expect(source.channel).to eq(described_class::CHANNEL_DIRECT)
    end

    it 'ignores parameters that are not on the list' do
      source = described_class.from_request(request_double(params: { evil: 'x', gclid: 'y' }))

      expect(source.to_h.keys).to match_array(%w[landing_path first_seen_at])
    end

    it 'truncates an oversized value instead of storing it whole' do
      source = described_class.from_request(request_double(params: { ref: 'a' * 500 }))

      expect(source.to_h['ref'].length).to eq(described_class::MAX_VALUE_LENGTH)
    end

    describe 'the referrer' do
      it 'keeps only the host of a foreign referrer, never the path' do
        source = described_class.from_request(
          request_double(referer: 'https://www.google.com/search?q=geheime+suche')
        )

        expect(source.to_h['referrer_host']).to eq('www.google.com')
        expect(source.to_h.values.join).not_to include('geheime')
      end

      it 'drops an internal referrer, which says nothing about where someone came from' do
        source = described_class.from_request(
          request_double(referer: 'https://lalabase.com/pricing', host: 'lalabase.com')
        )

        expect(source.to_h).not_to have_key('referrer_host')
      end

      it 'survives an unparsable referrer' do
        source = described_class.from_request(request_double(referer: 'http://[oops'))

        expect(source.to_h).not_to have_key('referrer_host')
      end
    end
  end

  describe '#channel' do
    def channel_for(attributes)
      described_class.new(attributes.stringify_keys).channel
    end

    it 'prefers our own ref over everything else' do
      expect(channel_for(ref: 'mail-01', utm_source: 'linkedin', referrer_host: 'google.com'))
        .to eq('mail-01')
    end

    it 'falls back to utm_source when no ref was issued' do
      expect(channel_for(utm_source: 'linkedin', referrer_host: 'google.com')).to eq('linkedin')
    end

    it 'falls back to the referring host when nothing was declared' do
      expect(channel_for(referrer_host: 'news.ycombinator.com')).to eq('news.ycombinator.com')
    end

    it 'reports direct when there is nothing at all' do
      expect(channel_for(landing_path: '/')).to eq(described_class::CHANNEL_DIRECT)
    end
  end

  describe '.from_stored' do
    it 'returns nil for a missing or empty record' do
      expect(described_class.from_stored(nil)).to be_nil
      expect(described_class.from_stored({})).to be_nil
    end

    it 'drops keys that are not part of the contract' do
      source = described_class.from_stored('ref' => 'mail', 'injected' => 'x')

      expect(source.to_h).to eq('ref' => 'mail')
    end

    it 'survives a stored timestamp that no longer parses' do
      source = described_class.from_stored('ref' => 'mail', 'first_seen_at' => 'nicht-datum')

      expect(source.first_seen_at).to be_nil
      expect(source.channel).to eq('mail')
    end
  end
end

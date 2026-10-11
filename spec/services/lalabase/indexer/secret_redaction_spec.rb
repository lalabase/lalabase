# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::SecretRedaction do
  let(:token) { 'ghp_supersecrettoken' }

  describe '.redact' do
    it 'replaces EVERY occurrence of the token (global gsub, not just the first)' do
      msg = "auth #{token} failed, retry with #{token}"
      expect(described_class.redact(msg, token)).to eq('auth [REDACTED] failed, retry with [REDACTED]')
    end

    it 'returns the message unchanged when the token is blank or nil' do
      expect(described_class.redact('plain message', '')).to eq('plain message')
      expect(described_class.redact('plain message', nil)).to eq('plain message')
    end

    it 'coerces a non-string message to a string (no NoMethodError)' do
      expect(described_class.redact(12_345, token)).to eq('12345')
    end

    it 'leaves a message without the token untouched' do
      expect(described_class.redact('nothing secret here', token)).to eq('nothing secret here')
    end

    # The most likely real leak: git embeds the token in the clone URL, so a
    # clone failure surfaces it as https://x-access-token:<token>@github.com/…
    it 'scrubs a token embedded in a clone URL' do
      url = "fatal: unable to access 'https://x-access-token:#{token}@github.com/acme/repo.git/'"
      redacted = described_class.redact(url, token)
      expect(redacted).not_to include(token)
      expect(redacted).to include('[REDACTED]')
    end
  end

  describe '.scrub_exception' do
    it 'returns a same-class exception with redacted message AND backtrace' do
      original = RuntimeError.new("boom with #{token}")
      original.set_backtrace(["/app/x.rb:1 in `f' #{token}", '/app/y.rb:2'])

      scrubbed = described_class.scrub_exception(original, token)

      expect(scrubbed).to be_a(RuntimeError)
      expect(scrubbed.message).to eq('boom with [REDACTED]')
      expect(scrubbed.backtrace.first).to include('[REDACTED]')
      expect(scrubbed.backtrace.first).not_to include(token)
    end

    it 'preserves the original exception class (retry_on/discard_on semantics depend on it)' do
      original = Lalabase::Github::Client::RateLimitError.new("rate limited #{token}")
      expect(described_class.scrub_exception(original, token))
        .to be_a(Lalabase::Github::Client::RateLimitError)
    end

    it 'returns the SAME object unchanged when the token is blank' do
      original = RuntimeError.new('boom')
      expect(described_class.scrub_exception(original, '')).to equal(original)
    end

    it 'falls back to StandardError when the class cannot be rebuilt from a single string arg' do
      needs_two = Class.new(StandardError) do
        def initialize(first, second)
          super("#{first}/#{second}")
        end
      end
      original = needs_two.new('x', "y #{token}")

      scrubbed = described_class.scrub_exception(original, token)

      expect(scrubbed).to be_a(StandardError)
      expect(scrubbed).not_to be_a(needs_two)
      expect(scrubbed.message).not_to include(token)
    end

    # Some exceptions type-check their initialize arg → rebuilding from a String
    # raises TypeError, not ArgumentError. The redaction path must not itself blow up.
    it 'falls back to StandardError when rebuilding raises TypeError' do
      type_picky = Class.new(StandardError) do
        def initialize(arg)
          raise TypeError, 'wants a Symbol' unless arg.is_a?(Symbol)

          super(arg.to_s)
        end
      end
      original = type_picky.new(:"boom #{token}")

      scrubbed = described_class.scrub_exception(original, token)

      expect(scrubbed).to be_a(StandardError)
      expect(scrubbed).not_to be_a(type_picky)
      expect(scrubbed.message).not_to include(token)
    end

    # A freshly-built (never-raised) exception has backtrace == nil. The `|| []`
    # guard must hold, or scrub would NoMethodError on nil.map exactly in the
    # token-protection path.
    it 'does not crash when the original exception has no backtrace (nil)' do
      original = RuntimeError.new("boom #{token}")

      scrubbed = described_class.scrub_exception(original, token)

      expect(scrubbed.backtrace).to eq([])
      expect(scrubbed.message).to eq('boom [REDACTED]')
    end
  end
end

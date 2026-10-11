# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::ProvisioningConfiguration do
  let(:secret) { SecureRandom.hex(32) }
  let(:previous_secret) { SecureRandom.hex(32) }

  it 'is off without a configured secret' do
    configuration = described_class.new

    expect(configuration).not_to be_enabled
    expect(configuration.authenticated?('')).to be(false)
    expect(configuration.authenticated?(nil)).to be(false)
  end

  it 'accepts the configured secret and nothing else' do
    configuration = described_class.new(secret: secret)

    expect(configuration).to be_enabled
    expect(configuration.authenticated?(secret)).to be(true)
    expect(configuration.authenticated?(secret.succ)).to be(false)
    expect(configuration.authenticated?(secret.first(63))).to be(false)
  end

  it 'ignores surrounding whitespace, which a copied environment file brings along' do
    expect(described_class.new(secret: "  #{secret}\n").authenticated?(secret)).to be(true)
  end

  it 'refuses a secret shorter than the minimum instead of guarding accounts with it' do
    short = 'a' * (described_class::MINIMUM_SECRET_LENGTH - 1)
    configuration = described_class.new(secret: short)

    expect(configuration).not_to be_enabled
    expect(configuration.authenticated?(short)).to be(false)
    expect(configuration.rejected_secret?).to be(true)
  end

  it 'reports nothing rejected when no secret is configured at all' do
    expect(described_class.new.rejected_secret?).to be(false)
  end

  describe 'rotation' do
    it 'accepts the previous secret while both sides are switched over' do
      configuration = described_class.new(secret: secret, previous_secret: previous_secret)

      expect(configuration.authenticated?(secret)).to be(true)
      expect(configuration.authenticated?(previous_secret)).to be(true)
    end

    it 'stays shut when only the previous secret survived a botched rotation' do
      configuration = described_class.new(previous_secret: previous_secret)

      expect(configuration).not_to be_enabled
      expect(configuration.authenticated?(previous_secret)).to be(false)
    end
  end

  describe '.from_env' do
    it 'reads both names' do
      configuration = described_class.from_env(
        'LALABASE_PROVISIONING_SECRET' => secret,
        'LALABASE_PROVISIONING_SECRET_PREVIOUS' => previous_secret
      )

      expect(configuration.authenticated?(secret)).to be(true)
      expect(configuration.authenticated?(previous_secret)).to be(true)
    end

    it 'is off for an environment without the variables' do
      expect(described_class.from_env({})).not_to be_enabled
    end
  end
end

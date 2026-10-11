# frozen_string_literal: true

# Unit specs for the key-resolution module defined by
# config/initializers/active_record_encryption.rb (the module is defined at boot,
# so it is directly callable here). The guard spec next door pins the ABSENCE of
# key literals; this file pins the resolution behaviour itself: precedence,
# loud failure in deployed environments, stable derivation in local ones, and
# the transition-only previous scheme. Test values are dummies — no assertion
# ever touches a real key, and the raise-message spec proves no value leaks.
require 'rails_helper'

RSpec.describe ActiveRecordEncryptionKeys do
  let(:empty_credentials) { {} }

  describe '.resolve' do
    it 'prefers Rails credentials over ENV' do
      credentials = { active_record_encryption: { primary_key: 'from-credentials' } }
      env = { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => 'from-env' }

      expect(described_class.resolve(:primary_key, credentials: credentials, env: env)).to eq('from-credentials')
    end

    it 'falls back to ENV when credentials have no value' do
      env = { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => 'from-env' }

      expect(described_class.resolve(:primary_key, credentials: empty_credentials, env: env)).to eq('from-env')
    end

    it 'treats blank values as missing (no silent empty key)' do
      credentials = { active_record_encryption: { primary_key: '' } }
      env = { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => '' }

      expect(described_class.resolve(:primary_key, credentials: credentials, env: env)).to be_nil
    end
  end

  describe '.resolve_all!' do
    context 'in deployed environments (production/staging)' do
      let(:production) { ActiveSupport::EnvironmentInquirer.new('production') }
      let(:staging) { ActiveSupport::EnvironmentInquirer.new('staging') }

      it 'raises when keys are missing, naming the missing config but never a value' do
        partial_env = { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => 'dummy-present-value' }

        resolve = -> { described_class.resolve_all!(credentials: empty_credentials, rails_env: production, env: partial_env) }

        expect(&resolve).to raise_error(RuntimeError) do |error|
          expect(error.message).to include('deterministic_key', 'key_derivation_salt')
          expect(error.message).not_to include('dummy-present-value')
        end
      end

      it 'raises in staging too — every deployed environment needs real keys' do
        expect do
          described_class.resolve_all!(credentials: empty_credentials, rails_env: staging, env: {})
        end.to raise_error(RuntimeError, /not configured/)
      end

      it 'generates RANDOM throwaway keys in a build context instead of raising (SECRET_KEY_BASE_DUMMY) — loudly' do
        # Rails' own build-step signal: the standard Dockerfile and this app's
        # local pre-deploy assets:precompile boot production WITHOUT the real
        # keys. A build decrypts nothing, so random throwaway keys are fine —
        # but ONLY under this flag; the raise specs above pin that a real
        # production boot still aborts. The warning is part of the contract:
        # this is the only non-raising path in a deployed environment, and a
        # RUNNING server that lands here (flag left behind in dotenv) must
        # never look like a correctly configured boot. RANDOM per boot instead
        # of the stable secret_key_base derivation dev/test use, deliberately:
        # a server accidentally on this path writes tokens that stop reading on
        # its next restart — the mistake surfaces in days, not months.
        env = { 'SECRET_KEY_BASE_DUMMY' => '1' }
        keys = nil

        expect do
          keys = described_class.resolve_all!(
            credentials: empty_credentials, rails_env: production, env: env, secret_key_base: nil
          )
        end.to output(/THROWAWAY keys/).to_stderr

        expect(keys.values).to all(match(/\A[0-9a-f]{64}\z/))

        # Pin the randomness: a second resolution must NOT reproduce the keys
        # (stable reproduction would be the hidden-for-months failure mode).
        second = nil
        expect do
          second = described_class.resolve_all!(
            credentials: empty_credentials, rails_env: production, env: env, secret_key_base: nil
          )
        end.to output(/THROWAWAY keys/).to_stderr
        expect(second.values & keys.values).to be_empty
      end

      it 'returns the resolved keys when all three are present' do
        env = {
          'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => 'dummy-primary',
          'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY' => 'dummy-deterministic',
          'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT' => 'dummy-salt'
        }

        keys = described_class.resolve_all!(credentials: empty_credentials, rails_env: production, env: env)

        expect(keys).to eq(
          primary_key: 'dummy-primary',
          deterministic_key: 'dummy-deterministic',
          key_derivation_salt: 'dummy-salt'
        )
      end
    end

    context 'in local environments (development/test)' do
      let(:development) { ActiveSupport::EnvironmentInquirer.new('development') }

      it 'derives missing keys from secret_key_base: stable and pairwise distinct' do
        first = described_class.resolve_all!(
          credentials: empty_credentials, rails_env: development, env: {}, secret_key_base: 'local-base'
        )
        second = described_class.resolve_all!(
          credentials: empty_credentials, rails_env: development, env: {}, secret_key_base: 'local-base'
        )

        expect(first).to eq(second) # deterministic — data stays readable across boots
        expect(first.values).to all(match(/\A[0-9a-f]{64}\z/))
        expect(first.values.uniq.size).to eq(3) # one key per purpose, never shared
      end

      it 'still prefers explicitly configured keys over derivation' do
        env = { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => 'dummy-explicit' }

        keys = described_class.resolve_all!(
          credentials: empty_credentials, rails_env: development, env: env, secret_key_base: 'local-base'
        )

        expect(keys[:primary_key]).to eq('dummy-explicit')
      end

      it 'refuses to derive without a secret_key_base' do
        expect do
          described_class.resolve_all!(credentials: empty_credentials, rails_env: development, env: {})
        end.to raise_error(ArgumentError, /secret_key_base/)
      end
    end
  end

  # NOTE: derivation-level assertions only. Whether the resulting scheme
  # actually DECRYPTS old ciphertext is proven end-to-end by
  # spec/config/active_record_encryption_rotation_spec.rb — a pure
  # "code equals its own derivation" check stayed green while rotation was broken.
  describe '.previous_key_secrets' do
    it 'is empty without the transition ENV vars' do
      expect(described_class.previous_key_secrets(env: {})).to eq([])
    end

    # Half a scheme decrypts nothing — and a clean boot WITHOUT the previous
    # scheme, while the operator believes the rotation transition is active,
    # is exactly the silent "looks configured, is not" defect this initializer
    # exists to eliminate. Both halves raise, each naming ONLY the missing
    # variable (never a value); both directions are pinned so neither side of
    # the guard can be dropped without a red example.
    it 'raises when only the previous primary key is set, naming the missing salt variable' do
      env = { 'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY' => 'dummy-old-primary' }

      resolve = -> { described_class.previous_key_secrets(env: env) }

      expect(&resolve).to raise_error(RuntimeError) do |error|
        expect(error.message).to include('ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT')
        expect(error.message).not_to include('dummy-old-primary')
      end
    end

    it 'raises when only the previous salt is set, naming the missing primary key variable' do
      env = { 'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT' => 'dummy-old-salt' }

      resolve = -> { described_class.previous_key_secrets(env: env) }

      expect(&resolve).to raise_error(RuntimeError) do |error|
        expect(error.message).to include('ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY')
        expect(error.message).not_to include('dummy-old-salt')
      end
    end

    it 'returns exactly one raw secret when both transition vars are set' do
      env = {
        'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY' => 'dummy-old-primary',
        'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT' => 'dummy-old-salt'
      }

      expect(described_class.previous_key_secrets(env: env).size).to eq(1)
    end
  end

  describe '.previous_scheme_properties' do
    it 'wraps the derived raw key in a ready KeyProvider (key_provider:, never key:)' do
      env = {
        'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY' => 'dummy-old-primary',
        'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT' => 'dummy-old-salt'
      }

      properties = described_class.previous_scheme_properties(env: env)

      expect(properties.size).to eq(1)
      # key_provider: survives Scheme#to_h/#merge and is used as-is; a key:
      # property would be dropped there and re-derived under the NEW salt.
      expect(properties.first.keys).to eq([:key_provider])
      expected = ActiveSupport::KeyGenerator.new('dummy-old-primary', hash_digest_class: OpenSSL::Digest::SHA256)
                                            .generate_key('dummy-old-salt', described_class::AES_256_GCM_KEY_LENGTH)
      expect(properties.first[:key_provider].encryption_key.secret).to eq(expected)
    end
  end
end

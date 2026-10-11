# frozen_string_literal: true

# What: Roundtrip proof of the key-rotation path — ciphertext written under an
#   OLD keyset must decrypt after the app rotates to a NEW keyset with the
#   previous READ scheme configured EXACTLY the way the initializer builds it
#   (ActiveRecordEncryptionKeys.previous_scheme_properties).
# Why: derivation-level unit specs can only compare the code with itself — 15
#   of them were green while the rotation scheme decrypted nothing. A previous
#   scheme passed as `key:` is dropped by Scheme#merge (key is not part of
#   Scheme#to_h) AND would be re-derived under the NEW salt. Only
#   encrypt-under-A / rotate-to-B / read closes that hole; the second example
#   proves the roundtrip is not vacuously green.
require 'rails_helper'

RSpec.describe 'Active Record encryption key rotation (roundtrip)' do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Dummy transition keysets — never real values.
  let(:old_keyset) { { primary_key: 'rotation-old-primary', key_derivation_salt: 'rotation-old-salt' } }
  let(:new_keyset) { { primary_key: 'rotation-new-primary', key_derivation_salt: 'rotation-new-salt' } }
  let(:previous_env) do
    {
      'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY' => old_keyset[:primary_key],
      'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT' => old_keyset[:key_derivation_salt]
    }
  end

  # Swap the GLOBAL keyset (encryption context is rebuilt; attribute types pick
  # key providers up dynamically) and restore everything afterwards. Every flag
  # is passed from the CAPTURED app config, never as a literal: a literal that
  # happens to match today's default becomes a global leak the day the default
  # flips (support_unencrypted_data goes false in the follow-up PR — a
  # hardcoded `true` here would silently re-enable it for every spec that runs
  # after this file in the same process, in random-order runs only).
  # support_sha1_for_non_deterministic_encryption is the one exception — it is
  # WRITE-ONLY state (no reader exists; `true` merely APPENDS an SHA1 previous
  # scheme on every call), so it cannot be captured. It MUST still be passed
  # explicitly as false (the app default per load_defaults 7.2): configure
  # defaults it to true and would leak one extra global scheme per call.
  def configure_keyset(primary_key:, key_derivation_salt:)
    ActiveRecord::Encryption.configure(
      primary_key: primary_key,
      deterministic_key: @original[:deterministic_key],
      key_derivation_salt: key_derivation_salt,
      support_unencrypted_data: @original[:support_unencrypted_data],
      extend_queries: @original[:extend_queries],
      support_sha1_for_non_deterministic_encryption: false
    )
  end

  around do |example|
    config = ActiveRecord::Encryption.config
    @original = {
      primary_key: config.primary_key,
      deterministic_key: config.deterministic_key,
      key_derivation_salt: config.key_derivation_salt,
      support_unencrypted_data: config.support_unencrypted_data,
      extend_queries: config.extend_queries,
      previous_schemes: config.previous_schemes.dup
    }
    example.run
  ensure
    # Order matters: configure first, THEN restore previous_schemes — the other
    # way round any scheme configure might append would survive the restore.
    configure_keyset(
      primary_key: @original[:primary_key],
      key_derivation_salt: @original[:key_derivation_salt]
    )
    ActiveRecord::Encryption.config.previous_schemes = @original[:previous_schemes]
  end

  # Previous schemes are baked into an attribute's scheme when `encrypts` is
  # DECLARED, not when it decrypts — a fresh reader class is the only way to
  # exercise the rotated config the way a production boot does.
  def fresh_reader_class
    Class.new(ApplicationRecord) do
      self.table_name = 'project_repositories'
      encrypts :access_token, deterministic: false
    end
  end

  it 'reads ciphertext written under the previous keyset via the initializer construction' do
    configure_keyset(**old_keyset)
    repo = create(:project_repository, access_token: 'rotate-me-token')

    configure_keyset(**new_keyset)
    ActiveRecord::Encryption.config.previous_schemes = []
    ActiveRecord::Encryption.config.previous =
      ActiveRecordEncryptionKeys.previous_scheme_properties(env: previous_env)

    expect(fresh_reader_class.find(repo.id).access_token).to eq('rotate-me-token')
  end

  it 'cannot read that ciphertext without the previous scheme (roundtrip is not vacuous)' do
    configure_keyset(**old_keyset)
    repo = create(:project_repository, access_token: 'rotate-me-token')

    configure_keyset(**new_keyset)
    ActiveRecord::Encryption.config.previous_schemes = []

    # Flag-aware: HOW the failure surfaces depends on support_unencrypted_data
    # (captured from the app config, so this example survives the flip to
    # false). What must hold either way: the token never comes back.
    reader = fresh_reader_class
    if @original[:support_unencrypted_data]
      # Bridge still on: the raw envelope comes back instead of raising — the
      # read "succeeds" but yields ciphertext, never the token.
      value = reader.find(repo.id).access_token
      expect(value).not_to eq('rotate-me-token')
      expect(ActiveRecord::Encryption.encryptor.encrypted?(value)).to be(true)
    else
      # Hard cutoff: undecryptable ciphertext raises instead of leaking through.
      expect { reader.find(repo.id).access_token }
        .to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    end
  end
end

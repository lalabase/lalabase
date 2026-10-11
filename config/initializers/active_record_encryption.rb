# frozen_string_literal: true

# Active Record encryption key configuration. Protects every `encrypts` column:
# ai_credentials.access_token, project_repositories.access_token/webhook_secret,
# organisations.ai_access_token/embedding_access_token, embedding_spaces.access_token.
#
# ── How to handle the keys ───────────────────────────────────────────────────
#
# There are three keys (primary_key, deterministic_key, key_derivation_salt).
# Generate a fresh set with `bin/rails db:encryption:init`. Per environment:
#
# * production / staging — REQUIRED. Put them into the server's dotenv file
#   (with Capistrano: shared/.env of the deploy directory — this app reads its
#   production ENV from dotenv, NOT from systemd, so `systemctl show` will
#   never show them; verify via `bin/rails runner` in current/). Keep a second
#   copy in the password manager: a database backup without these keys has
#   ciphertext columns forever — the backup's age key alone is not enough.
#   Without the keys the app REFUSES TO BOOT. That is intentional; do not
#   "fix" a failing boot by inventing values — restore the real ones.
# * development / test / CI — nothing to do. Missing keys are derived from
#   secret_key_base: stable per machine, never committed, and worthless as
#   secrets (they only protect local data).
# * build steps (assets:precompile before a deploy, Docker image builds) —
#   run with SECRET_KEY_BASE_DUMMY=1, exactly like the Rails standard
#   Dockerfile. The build gets RANDOM throwaway keys; it never decrypts data.
#   The production keys must NEVER be copied to a developer machine for this.
# * key rotation — set the two ACTIVE_RECORD_ENCRYPTION_PREVIOUS_* variables
#   (old primary_key + old key_derivation_salt) NEXT TO the new keys, deploy,
#   run `bin/rails encryption:reencrypt_tokens`, verify it reports zero
#   skipped rows, then DELETE the PREVIOUS_* variables and restart (incl.
#   Solid Queue workers — separate processes, separately loaded config).
#   Full step-by-step order with verification snippets:
#   docs/letzte_arbeiten/2026_08_04_4_letzte_arbeiten_encryption_scharfschalten.md
#
# Never paste key values into code, specs, logs, error messages, tickets or
# chat — reference them only by ENV name. The guard spec scans config/ for
# 64-hex literals precisely because that has happened here before.
#
# ── Why it is built this way ─────────────────────────────────────────────────
#
# Until 2026-08 this file carried three hardcoded fallback keys and a blanket
# `rescue StandardError` that logged one line and let the app keep running with
# broken encryption. Production had neither credentials nor ENV set, so every
# "encrypted" value was protected by a key that ships with the source — worth
# nothing once the repo goes public, and multiplied into 35 days of backups.
# Each design decision below closes one aspect of that defect:
#
# * No fallback values, no rescue: a security measure that silently degrades
#   on misconfiguration is indistinguishable from no measure. Boot failure is
#   the ONLY signal an operator reliably notices.
# * Credentials/ENV as the only sources: keys must be able to differ per
#   environment and rotate without a code change or redeploy of secrets.
# * Local derivation instead of shared dev literals: a committed "dev key" is
#   one copy-paste away from becoming the prod key (that is exactly how the
#   original fallback ended up active in production).
# * Build exception via SECRET_KEY_BASE_DUMMY instead of skipping the check:
#   the narrow, Rails-blessed signal keeps "build boots without keys" from
#   widening into "production boots without keys".
# * The rotation READ scheme lives in ENV, not code, and is expected to be
#   REMOVED after the rotation — old ciphertext staying readable forever would
#   quietly keep the retired key alive.
#
# Guarded by spec/config/active_record_encryption_guard_spec.rb (no literals,
# no rescue, retired keys never active) and proven end-to-end by
# spec/config/active_record_encryption_rotation_spec.rb.
module ActiveRecordEncryptionKeys
  CREDENTIALS_SECTION = :active_record_encryption

  # ENV names, mirrored in .env.example / .env.production.example.
  ENV_KEYS = {
    primary_key: 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY',
    deterministic_key: 'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY',
    key_derivation_salt: 'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'
  }.freeze

  # Transition-only (key rotation): a previous READ scheme for ciphertext still
  # sitting under the retired key. Set both vars, run encryption:reencrypt_tokens,
  # verify, then remove them. No previous deterministic key on purpose — every
  # `encrypts` declaration in this app is `deterministic: false`.
  PREVIOUS_ENV_KEYS = {
    primary_key: 'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY',
    key_derivation_salt: 'ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT'
  }.freeze

  # Key length in bytes of Rails' default cipher (aes-256-gcm).
  AES_256_GCM_KEY_LENGTH = 32

  module_function

  # Resolution order per key: Rails credentials, then ENV. No source fallback.
  def resolve(name, credentials:, env: ENV)
    credentials.dig(CREDENTIALS_SECTION, name).presence || env[ENV_KEYS.fetch(name)].presence
  end

  # Rails' own signal for "production environment loaded as a BUILD step, not a
  # runtime" — the standard Dockerfile runs
  # `SECRET_KEY_BASE_DUMMY=1 rails assets:precompile`, and so does the precompile
  # a deploy runs before it uploads the assets. Booting there must not
  # demand the production keys (they live only on the server / in the password
  # manager); derived throwaway keys are fine because a build decrypts nothing.
  def build_context?(env: ENV)
    env['SECRET_KEY_BASE_DUMMY'].present?
  end

  # Returns all three keys or raises. Development/test derive missing keys
  # from secret_key_base (stable per machine — local data must stay readable
  # across boots); deployed build contexts get RANDOM per-boot keys instead:
  # a build never decrypts, and a running server that lands here by accident
  # (flag left in the dotenv) must not look healthy — with random keys its
  # writes become unreadable on the next restart instead of hiding for months
  # under a stable derived key. Neither path can ever yield a repo literal.
  def resolve_all!(credentials:, rails_env:, env: ENV, secret_key_base: nil)
    keys = ENV_KEYS.keys.index_with { |name| resolve(name, credentials:, env:) }
    missing = keys.select { |_, value| value.blank? }.keys
    return keys if missing.none?

    unless rails_env.local? || build_context?(env: env)
      raise "Active Record encryption is not configured: missing #{missing.join(', ')}. " \
            "Set Rails credentials (#{CREDENTIALS_SECTION}) or ENV " \
            "(#{missing.map { |name| ENV_KEYS.fetch(name) }.join(', ')}). " \
            'The app must not run without encryption keys.'
    end

    if rails_env.local?
      missing.each { |name| keys[name] = derived_local_key(name, secret_key_base) }
    else
      # Build context in a deployed environment. Random keys are correct for
      # assets:precompile — and loudly WRONG for a running server (real tokens
      # under throwaway keys, e.g. SECRET_KEY_BASE_DUMMY left behind in the
      # server's dotenv). Say it on both channels; this is the only
      # non-raising path left and it must never be mistaken for "configured".
      message = "Active Record encryption: generating random THROWAWAY keys for missing #{missing.join(', ')} " \
                '(SECRET_KEY_BASE_DUMMY build context). Fine for a build — NEVER for a running server.'
      warn(message)
      Rails.logger&.warn(message)
      missing.each { |name| keys[name] = SecureRandom.hex(AES_256_GCM_KEY_LENGTH) }
    end

    keys
  end

  # SHA-256 over secret_key_base + key name: deterministic per machine and
  # non-secret — it only ever protects local development/test data.
  def derived_local_key(name, secret_key_base)
    raise ArgumentError, 'secret_key_base required to derive local encryption keys' if secret_key_base.blank?

    Digest::SHA256.hexdigest("#{secret_key_base}/active_record_encryption/#{name}")
  end

  # Raw AES keys of the previous scheme (key rotation), from ENV. Derives them
  # the way Rails' KeyGenerator did when the old ciphertext was written (SHA-256
  # digest per load_defaults 7.1+) — necessary because the global
  # key_derivation_salt has already moved on to the new value at that point.
  def previous_key_secrets(env: ENV)
    primary = env[PREVIOUS_ENV_KEYS.fetch(:primary_key)].presence
    salt = env[PREVIOUS_ENV_KEYS.fetch(:key_derivation_salt)].presence
    return [] if primary.nil? && salt.nil?

    # Exactly one of the two set (typo in a variable name, one line removed
    # early): booting cleanly with NO previous scheme would be the silent
    # "looks configured, is not" failure this file exists to eliminate — the
    # operator believes the rotation transition is active while every legacy
    # row reads back as ciphertext. Half a scheme decrypts nothing: name the
    # missing variable (never a value) and refuse to boot.
    if primary.nil? || salt.nil?
      missing = primary.nil? ? PREVIOUS_ENV_KEYS.fetch(:primary_key) : PREVIOUS_ENV_KEYS.fetch(:key_derivation_salt)
      raise "Active Record encryption: previous READ scheme is half-configured — #{missing} is missing. " \
            'Set BOTH ACTIVE_RECORD_ENCRYPTION_PREVIOUS_* variables for a key rotation, or neither.'
    end

    [ActiveSupport::KeyGenerator.new(primary, hash_digest_class: OpenSSL::Digest::SHA256)
                                .generate_key(salt, AES_256_GCM_KEY_LENGTH)]
  end

  # Scheme properties for config.previous. The finished key MUST travel as a
  # key_provider: a bare `key:` property would be re-derived under the NEW salt
  # AND dropped entirely by Scheme#merge (key is not part of Scheme#to_h) — the
  # "previous" scheme then silently degrades to a copy of the current one.
  # Proven by spec/config/active_record_encryption_rotation_spec.rb.
  # References ActiveRecord constants — only call once Active Record is loaded
  # (from the on_load hook below, or from specs).
  def previous_scheme_properties(env: ENV)
    previous_key_secrets(env: env).map do |secret|
      { key_provider: ActiveRecord::Encryption::KeyProvider.new(ActiveRecord::Encryption::Key.new(secret)) }
    end
  end
end

Rails.application.configure do
  # secret_key_base only where LOCAL derivation happens — calling it eagerly in
  # a real production boot would mask the missing-keys error with Rails' own
  # missing-secret_key_base one. Deployed build contexts get random keys and
  # need no secret at all.
  keys = ActiveRecordEncryptionKeys.resolve_all!(
    credentials: Rails.application.credentials,
    rails_env: Rails.env,
    secret_key_base: Rails.env.local? ? Rails.application.secret_key_base : nil
  )

  config.active_record.encryption.primary_key = keys[:primary_key]
  config.active_record.encryption.deterministic_key = keys[:deterministic_key]
  config.active_record.encryption.key_derivation_salt = keys[:key_derivation_salt]

  # HARD CUTOFF (2026-08-05, after the production backfill via
  # encryption:reencrypt_tokens): a cleartext value in an encrypted column now
  # RAISES on read instead of being silently accepted. This is a date-gated
  # one-way switch, not a preference — flipping it back to true re-opens the
  # door for write paths that bypass `encrypts` to park cleartext unnoticed
  # (exactly the original ai_credentials defect). Environments with unrewritten
  # legacy rows must run encryption:reencrypt_tokens BEFORE deploying this line
  # — afterwards those rows are readable never, not later.
  config.active_record.encryption.support_unencrypted_data = false

  config.active_record.encryption.extend_queries = true
end

# Register the previous READ scheme (key rotation) the moment Active Record's
# encryption loads: AFTER the railtie has applied the config above (its own
# on_load callback is registered earlier, so it runs first) and BEFORE any
# encrypted attribute's scheme is MATERIALIZED. Rails reads
# config.previous_schemes lazily, when a model's attribute types are first
# built (in practice: model/schema load, right after boot) — `encrypts` itself
# only registers a decorator. Registering the previous scheme any later (from
# an after_initialize, a request, a job) would leave every already-built
# attribute without it, silently.
ActiveSupport.on_load(:active_record_encryption) do
  properties = ActiveRecordEncryptionKeys.previous_scheme_properties
  ActiveRecord::Encryption.config.previous = properties if properties.any?
end

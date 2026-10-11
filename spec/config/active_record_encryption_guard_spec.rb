# frozen_string_literal: true

# What: Guard spec — no Active Record encryption key may exist as a literal in
#   the repo's config, and the encryption initializer may not rescue its own
#   configuration.
# Why (history): Until 2026-08 the initializer carried three hardcoded fallback
#   keys and a blanket `rescue StandardError` that logged one line and let the
#   app keep running with broken encryption. Production never had credentials or
#   ENV set, so EVERY encrypted value (ai_credentials, project_repositories) was
#   protected by a key that ships with the source — worthless the moment the
#   repo goes public. A fallback key and a silent rescue are the same defect in
#   two forms: the security measure disappears while everything looks configured.
# Contract:
#   * config/ never contains a hex key literal of 64 or more chars (including Devise's 128)
#   * config/ never contains a 32-alphanumeric key literal (the format
#     `bin/rails db:encryption:init` emits — the command our own docs prescribe)
#   * the initializer has no rescue — a boot without keys must fail loudly
#   * the previous READ scheme is registered inside on_load(:active_record_encryption)
#   * the running app never uses one of the retired, publicly burned keys
require 'rails_helper'

RSpec.describe 'Active Record encryption key guard' do
  let(:initializer_path) { Rails.root.join('config/initializers/active_record_encryption.rb') }
  let(:initializer_source) { File.read(initializer_path) }

  # Everywhere a config-level key literal could plausibly reappear — ALL Ruby
  # files under config/, not a hand-picked subset (a neighbouring initializer
  # is exactly as likely a hiding place as this one). Credentials files
  # (*.yml.enc) are ciphertext and deliberately out of scope.
  let(:scanned_config_files) { Dir[Rails.root.join('config/**/*.rb')] }

  # The exact keys that shipped in source until 2026-08. They are burned (public
  # in git history) and listed here so no config path can ever resurrect them.
  # Keeping them in a spec leaks nothing: rotation retired them for good.
  let(:retired_keys) do
    %w[
      2746702af6328040991c1d42831116d1a635fd12f83e9a39dc364e712b02131b
      6f92256ed9498070b2bdbfc17724d3f6c788da7f0ebfc15d8155260c498a22e0
      4901fbef8e395683bbcaa4696a8eda00e69d9e993a83ae644f2469c9c144586c
    ]
  end

  def hex_key_literals(source)
    source.scan(/\b[0-9a-f]{64,}\b/i)
  end

  it 'keeps config/ free of hex key literals of 64 or more chars' do
    offenders = scanned_config_files.filter_map do |file|
      hits = hex_key_literals(File.read(file))
      "#{file}: #{hits.count} hex literal(s)" if hits.any?
    end

    expect(offenders).to be_empty, <<~MSG
      Encryption keys (or other long hex secrets) must never live in config
      as literals — resolve them via Rails credentials or ENV. Offenders:
      #{offenders.join("\n")}
    MSG
  end

  it 'also catches longer keys in comments, including the Devise secret format' do
    [64, 128].each do |length|
      example_key = SecureRandom.hex(length / 2)
      expect(hex_key_literals("# config.secret_key = '#{example_key}'")).to eq([example_key])
    end
  end

  # The hex rule above does not cover the format emitted by the command our
  # docs and .env examples prescribe (`bin/rails db:encryption:init`): it emits
  # SecureRandom.alphanumeric(32) — a freshly hardcoded key in the project's own
  # format would sail past a hex-only scan. Exactly 32 chars with at least one
  # digit and one letter. Longer hex secrets are covered by the rule above;
  # a word-boundary match cannot fire inside those longer runs anyway. ONE
  # implementation shared by the rule and its mutation probe below, so the
  # probe can never drift apart from what the rule actually scans.
  def init_format_key_literals(source)
    source.scan(/\b[A-Za-z0-9]{32}\b/)
          .select { |token| token.match?(/\d/) && token.match?(/[A-Za-z]/) }
  end

  it 'keeps config/ free of 32-alphanumeric key literals (db:encryption:init format)' do
    offenders = scanned_config_files.filter_map do |file|
      hits = init_format_key_literals(File.read(file))
      "#{file}: #{hits.count} candidate key literal(s)" if hits.any?
    end

    expect(offenders).to be_empty, <<~MSG
      Encryption keys in the db:encryption:init format (32 alphanumeric chars)
      must never live in config as literals — resolve them via Rails
      credentials or ENV. Offenders:
      #{offenders.join("\n")}
    MSG
  end

  # Mutation probe: a source line carrying a key in the CURRENT generator
  # format must be flagged, and the retired 64-hex format must stay with the
  # hex rule — proves the format scan is neither vacuous nor redundant.
  it 'flags a key literal in the db:encryption:init format (scan is not hex-only)' do
    fixture_key = "k1#{SecureRandom.alphanumeric(30)}" # 32 chars, letter + digit guaranteed

    expect(init_format_key_literals("primary_key = '#{fixture_key}'")).to eq([fixture_key])
    expect(init_format_key_literals("primary_key = '#{retired_keys.first}'")).to be_empty
  end

  it 'has no rescue in the encryption initializer (missing keys must abort boot)' do
    # Comments may mention the word (the header documents the old defect) —
    # only code lines count.
    code_lines = initializer_source.lines.reject { |line| line.strip.start_with?('#') }

    expect(code_lines.join).not_to match(/\brescue\b/), <<~MSG
      config/initializers/active_record_encryption.rb rescues its own
      configuration again. A boot without encryption keys must fail loudly —
      a rescue here silently disables encryption (the original defect).
    MSG
  end

  it 'registers the previous READ scheme inside the on_load(:active_record_encryption) hook' do
    # The rotation roundtrip spec proves the CONSTRUCTION of the previous
    # scheme but assigns config.previous by hand — it never runs the hook. The
    # registration must live inside on_load(:active_record_encryption): Rails
    # reads config.previous_schemes lazily when an attribute's scheme is first
    # MATERIALIZED (model/schema load, right after boot), so code that assigns
    # config.previous after models load (or not at all) leaves rotation
    # silently dead while every other spec stays green. Source-level pin:
    # deleting or relocating the block turns this red.
    hook_block = initializer_source[/ActiveSupport\.on_load\(:active_record_encryption\)\s+do.*?\bend\b/m]

    expect(hook_block).to be_present, <<~MSG
      The on_load(:active_record_encryption) hook is gone from the encryption
      initializer. Without it the previous READ scheme is never registered and
      key rotation is silently dead (attribute schemes materialize right after
      boot and never see a later registration).
    MSG
    expect(hook_block).to include('previous_scheme_properties')
    expect(hook_block).to match(/\.previous\s*=/)
  end

  it 'keeps support_unencrypted_data hard off (the cutoff is one-way)' do
    # Since 2026-08-05 (production backfill done) a cleartext value in an
    # encrypted column is a defect that must RAISE on read. Turning the bridge
    # back on would let write paths that bypass `encrypts` park cleartext
    # unnoticed again — the original ai_credentials defect. Pinned twice:
    # the LIVE config value and the explicit line in the initializer.
    expect(ActiveRecord::Encryption.config.support_unencrypted_data).to be(false)
    expect(initializer_source).to match(/support_unencrypted_data\s*=\s*false\b/)
  end

  it 'never runs on one of the retired, publicly burned keys' do
    config = ActiveRecord::Encryption.config

    expect(config.primary_key).to be_present
    expect(config.deterministic_key).to be_present
    expect(config.key_derivation_salt).to be_present
    expect(retired_keys).not_to include(
      config.primary_key, config.deterministic_key, config.key_derivation_salt
    )
  end

  it 'uses no deterministic encryption anywhere (the rotation READ scheme covers only non-deterministic)' do
    # The initializer's PREVIOUS_* transition scheme deliberately carries no
    # previous deterministic key — valid ONLY while every encrypted attribute
    # is non-deterministic. A later `encrypts :x, deterministic: true` would
    # make that column silently unrotatable. Checked against the LIVE attribute
    # schemes (mechanism, not source text), so an `encrypts` from any concern
    # or gem-provided model counts too.
    Rails.application.eager_load!

    deterministic = ActiveRecord::Base.descendants.flat_map do |klass|
      next [] if klass.abstract_class? || klass.encrypted_attributes.blank?

      klass.encrypted_attributes.filter_map do |attribute|
        "#{klass.name}##{attribute}" if klass.type_for_attribute(attribute).scheme.deterministic?
      end
    end

    expect(deterministic).to be_empty, <<~MSG
      Deterministic encryption appeared, but the rotation transition scheme
      (ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*) only rebuilds the non-deterministic
      key. Extend previous_scheme_properties with a previous deterministic key
      before shipping this attribute:
      #{deterministic.join("\n")}
    MSG
  end
end

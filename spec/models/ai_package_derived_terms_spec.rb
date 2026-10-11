# frozen_string_literal: true

require 'rails_helper'

# What this protects: the customer card must never promise more than the
# weakest credential delivers. The package stores nothing — it reads its
# credentials' assessments, and the STRICTEST answer wins.
RSpec.describe AiPackage, 'derived contractual terms' do
  def credential_with(training: nil, retention: nil, days: nil, subprocessors: nil)
    credential = create(:ai_credential)
    if training || retention || subprocessors
      create(:ai_credential_contract,
             ai_credential: credential, starts_on: Date.current, retention_days: days,
             training_usage: training || AiCredentialContract::TRAINING_UNSPECIFIED,
             retention_policy: retention || AiCredentialContract::RETENTION_UNSPECIFIED,
             subprocessors_disclosure: subprocessors || AiCredentialContract::SUBPROCESSORS_UNSPECIFIED)
    end
    credential
  end

  # Preloaded exactly as the customer catalogue does it. The pause covers only
  # the SETUP: loading two associations one by one looks like an N+1 to
  # Prosopite, while the catalogue does it in a single `includes` — the
  # derivation under test issues no query at all afterwards.
  def package_with(*credentials, jurisdiction: 'eu_native')
    Prosopite.pause { credentials.each { |credential| credential.contracts.load } }
    package = build(:ai_package, embedding_credential: credentials.first, jurisdiction: jurisdiction)
    credentials.drop(1).each_with_index do |credential, index|
      key = AiPackageTier::KEYS[index]
      package.tiers.build(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                          chat_credential: credential)
    end
    package
  end

  describe '#derived_training_usage' do
    it 'reports the exclusion when every credential excludes training' do
      excluded = AiCredentialContract::TRAINING_EXCLUDED
      package = package_with(credential_with(training: excluded), credential_with(training: excluded))

      expect(package.derived_training_usage).to eq(excluded)
    end

    # The whole point of deriving: a package cannot promise more than its
    # weakest credential delivers.
    it 'reports training when a SINGLE credential trains' do
      package = package_with(credential_with(training: AiCredentialContract::TRAINING_EXCLUDED),
                             credential_with(training: AiCredentialContract::TRAINING_USED))

      expect(package.derived_training_usage).to eq(AiCredentialContract::TRAINING_USED)
    end

    it 'degrades to unspecified when one credential was never assessed' do
      package = package_with(credential_with(training: AiCredentialContract::TRAINING_EXCLUDED),
                             credential_with)

      expect(package.derived_training_usage).to eq(AiCredentialContract::TRAINING_UNSPECIFIED)
    end

    it 'prefers the worse answer over the unassessed one' do
      package = package_with(credential_with(training: AiCredentialContract::TRAINING_USED),
                             credential_with)

      expect(package.derived_training_usage).to eq(AiCredentialContract::TRAINING_USED)
    end

    # A card must render a badge either way, and "no credentials" is certainly
    # not an assurance.
    it 'answers unspecified for a package without credentials' do
      package = build(:ai_package, embedding_credential: nil)

      expect(package.derived_training_usage).to eq(AiCredentialContract::TRAINING_UNSPECIFIED)
    end

    # Self-hosted is the exception the card already makes for the legal
    # classification: no third party receives data, so the question is
    # groundless rather than unanswered. A grey "not assured" badge there would
    # be a false warning.
    it 'answers nil for a self-hosted package' do
      package = package_with(credential_with, jurisdiction: 'self_hosted')

      expect(package.derived_training_usage).to be_nil
    end

    # Versioning is the reason this is a table: the answer depends on WHEN.
    it 'reads the version in force on the given date' do
      credential = create(:ai_credential)
      create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current - 90.days,
                                      ends_on: Date.current - 1.day,
                                      training_usage: AiCredentialContract::TRAINING_USED)
      create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current,
                                      training_usage: AiCredentialContract::TRAINING_EXCLUDED)
      package = package_with(credential)

      expect(package.derived_training_usage(Date.current - 30.days))
        .to eq(AiCredentialContract::TRAINING_USED)
      expect(package.derived_training_usage).to eq(AiCredentialContract::TRAINING_EXCLUDED)
    end

    # Intended: if the last version expires and none follows, the statement falls
    # back to "nicht zugesichert" instead of holding on to an expired assurance.
    it 'degrades once the last assessment has expired' do
      credential = create(:ai_credential)
      create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current - 90.days,
                                      ends_on: Date.current - 1.day,
                                      training_usage: AiCredentialContract::TRAINING_EXCLUDED)
      package = package_with(credential)

      expect(package.derived_training_usage).to eq(AiCredentialContract::TRAINING_UNSPECIFIED)
    end
  end

  describe '#derived_retention' do
    it 'reports none when every credential keeps nothing' do
      none = AiCredentialContract::RETENTION_NONE
      package = package_with(credential_with(retention: none), credential_with(retention: none))

      expect(package.derived_retention).to eq([none, nil])
    end

    # Naming the smaller number would be the prettier and therefore false
    # statement.
    it 'names the HIGHEST day count among limited credentials' do
      limited = AiCredentialContract::RETENTION_LIMITED
      package = package_with(credential_with(retention: limited, days: 30),
                             credential_with(retention: limited, days: 90))

      expect(package.derived_retention).to eq([limited, 90])
    end

    it 'lets unlimited outrank everything' do
      package = package_with(credential_with(retention: AiCredentialContract::RETENTION_NONE),
                             credential_with(retention: AiCredentialContract::RETENTION_UNLIMITED))

      expect(package.derived_retention.first).to eq(AiCredentialContract::RETENTION_UNLIMITED)
    end

    it 'lets unspecified outrank limited' do
      package = package_with(credential_with(retention: AiCredentialContract::RETENTION_LIMITED, days: 30),
                             credential_with)

      expect(package.derived_retention.first).to eq(AiCredentialContract::RETENTION_UNSPECIFIED)
    end

    it 'answers nil for a self-hosted package' do
      expect(package_with(credential_with, jurisdiction: 'self_hosted').derived_retention).to be_nil
    end
  end

  # The third axis. It carries a column, a validation, a form field and a
  # display, so it needs the same aggregation as the other two — otherwise the
  # customer card has no answer to give for it.
  describe '#derived_subprocessors_disclosure' do
    it 'reports disclosure when every credential discloses' do
      disclosed = AiCredentialContract::SUBPROCESSORS_DISCLOSED
      package = package_with(credential_with(subprocessors: disclosed),
                             credential_with(subprocessors: disclosed))

      expect(package.derived_subprocessors_disclosure).to eq(disclosed)
    end

    it 'reports undisclosed when a SINGLE credential names nobody' do
      package = package_with(credential_with(subprocessors: AiCredentialContract::SUBPROCESSORS_DISCLOSED),
                             credential_with(subprocessors: AiCredentialContract::SUBPROCESSORS_UNDISCLOSED))

      expect(package.derived_subprocessors_disclosure)
        .to eq(AiCredentialContract::SUBPROCESSORS_UNDISCLOSED)
    end

    it 'degrades to unspecified when one credential was never assessed' do
      package = package_with(credential_with(subprocessors: AiCredentialContract::SUBPROCESSORS_DISCLOSED),
                             credential_with)

      expect(package.derived_subprocessors_disclosure)
        .to eq(AiCredentialContract::SUBPROCESSORS_UNSPECIFIED)
    end

    # The settled bad answer outranks the open question, same as with training.
    it 'prefers undisclosed over the unassessed one' do
      package = package_with(credential_with(subprocessors: AiCredentialContract::SUBPROCESSORS_UNDISCLOSED),
                             credential_with)

      expect(package.derived_subprocessors_disclosure)
        .to eq(AiCredentialContract::SUBPROCESSORS_UNDISCLOSED)
    end

    it 'answers unspecified for a package without credentials' do
      expect(build(:ai_package, embedding_credential: nil).derived_subprocessors_disclosure)
        .to eq(AiCredentialContract::SUBPROCESSORS_UNSPECIFIED)
    end

    it 'answers nil for a self-hosted package' do
      package = package_with(credential_with, jurisdiction: 'self_hosted')

      expect(package.derived_subprocessors_disclosure).to be_nil
    end

    it 'reads the version in force on the given date' do
      credential = create(:ai_credential)
      create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current - 90.days,
                                      ends_on: Date.current - 1.day,
                                      subprocessors_disclosure: AiCredentialContract::SUBPROCESSORS_UNDISCLOSED)
      create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current,
                                      subprocessors_disclosure: AiCredentialContract::SUBPROCESSORS_DISCLOSED)
      package = package_with(credential)

      expect(package.derived_subprocessors_disclosure(Date.current - 30.days))
        .to eq(AiCredentialContract::SUBPROCESSORS_UNDISCLOSED)
      expect(package.derived_subprocessors_disclosure)
        .to eq(AiCredentialContract::SUBPROCESSORS_DISCLOSED)
    end
  end

  describe 'AiCredential#contract_on' do
    # Two code paths for the same question are a drift point: the loaded
    # association filters in memory, the unloaded one queries.
    it 'answers identically whether the association is loaded or not' do
      credential = create(:ai_credential)
      contract = create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current)

      unloaded = AiCredential.find(credential.id).contract_on
      loaded = AiCredential.find(credential.id).tap { |c| c.contracts.load }.contract_on

      expect(unloaded).to eq(contract)
      expect(loaded).to eq(contract)
    end
  end

  describe 'badge styles' do
    it 'has exactly one style per training value' do
      expect(described_class::TRAINING_USAGE_BADGE_STYLES.keys)
        .to match_array(AiCredentialContract::TRAINING_USAGES)
    end
  end
end

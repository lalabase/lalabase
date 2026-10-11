# frozen_string_literal: true

require 'rails_helper'

# What this protects: the assessed version is a STATEMENT the operator makes to
# their own customers, and it must never claim more than was verified. Hence
# three-valued axes with an "unspecified" default, and hence the no-overlap rule
# — "what did we state on date X" needs exactly one answer.
RSpec.describe AiCredentialContract do
  it_behaves_like 'an effectively dated record' do
    let(:expected_scope_columns) { [:ai_credential_id] }
    let(:credential) { create(:ai_credential) }

    def dated_record(attrs = {})
      build(:ai_credential_contract, ai_credential: credential, **attrs)
    end

    def dated_record!(attrs = {})
      create(:ai_credential_contract, ai_credential: credential, **attrs)
    end
  end

  describe 'defaults' do
    # A credential nobody assessed must not assert a promise. Every axis starts
    # at its unspecified variant, and the card shows that state openly.
    it 'starts unspecified on every axis' do
      contract = create(:ai_credential_contract)

      expect(contract.training_usage).to eq(described_class::TRAINING_UNSPECIFIED)
      expect(contract.retention_policy).to eq(described_class::RETENTION_UNSPECIFIED)
      expect(contract.subprocessors_disclosure).to eq(described_class::SUBPROCESSORS_UNSPECIFIED)
    end
  end

  describe 'value ranges' do
    it 'accepts every declared training value' do
      described_class::TRAINING_USAGES.each do |value|
        expect(build(:ai_credential_contract, training_usage: value)).to be_valid, value
      end
    end

    it 'accepts every declared retention policy' do
      described_class::RETENTION_POLICIES.each do |value|
        days = value == described_class::RETENTION_LIMITED ? 30 : nil
        expect(build(:ai_credential_contract, retention_policy: value, retention_days: days))
          .to be_valid, value
      end
    end

    it 'rejects an invented value' do
      expect(build(:ai_credential_contract, training_usage: 'maybe')).not_to be_valid
      expect(build(:ai_credential_contract, retention_policy: 'a while')).not_to be_valid
    end
  end

  describe 'retention_days' do
    # A day count next to "no retention" is a contradiction; a missing one under
    # 'limited' makes the statement useless.
    it 'is required when the policy is limited' do
      contract = build(:ai_credential_contract,
                       retention_policy: described_class::RETENTION_LIMITED, retention_days: nil)

      expect(contract).not_to be_valid
    end

    it 'is refused when the policy is not limited' do
      contract = build(:ai_credential_contract,
                       retention_policy: described_class::RETENTION_NONE, retention_days: 30)

      expect(contract).not_to be_valid
      expect(contract.errors[:retention_days]).to be_present
    end

    # The admin controller puts full_messages straight into the flash, so an
    # untranslated symbol reaches the operator as "Translation missing: …".
    # `be_present` above cannot catch that — the placeholder string is present
    # too, which is exactly how the gap shipped.
    it 'renders a translated message in both locales' do
      contract = build(:ai_credential_contract,
                       retention_policy: described_class::RETENTION_NONE, retention_days: 30)
      contract.validate

      expect(contract.errors[:retention_days].first).to include('befristeter Aufbewahrung')

      I18n.with_locale(:en) do
        english = build(:ai_credential_contract,
                        retention_policy: described_class::RETENTION_NONE, retention_days: 30)
        english.validate

        expect(english.errors[:retention_days].first).to include('limited retention')
      end
    end

    it 'is accepted with limited' do
      expect(build(:ai_credential_contract, retention_policy: described_class::RETENTION_LIMITED,
                                            retention_days: 30)).to be_valid
    end

    it 'rejects a non-positive count' do
      expect(build(:ai_credential_contract, retention_policy: described_class::RETENTION_LIMITED,
                                            retention_days: 0)).not_to be_valid
    end
  end

  # The no-overlap rule of EffectiveDating is app-level. Two concurrent requests
  # (a double-submitted form) both read the same running version, both clip it,
  # and neither validation sees the other's uncommitted row — so the promise
  # "exactly one answer per date" needs a guarantee below the app.
  describe 'the same start date twice' do
    it 'is refused by the database, not only by the validation' do
      credential = create(:ai_credential)
      create(:ai_credential_contract, ai_credential: credential, starts_on: Date.current)
      duplicate = build(:ai_credential_contract, ai_credential: credential, starts_on: Date.current)

      # validate: false skips the app-level overlap check on purpose — that is
      # exactly the state a racing second request reaches the INSERT in.
      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'still allows the same start date on a DIFFERENT credential' do
      starts_on = Date.current
      create(:ai_credential_contract, ai_credential: create(:ai_credential), starts_on: starts_on)

      expect(build(:ai_credential_contract, ai_credential: create(:ai_credential),
                                            starts_on: starts_on)).to be_valid
    end
  end

  describe 'severity orders' do
    # These orders decide what a customer reads. Worst first, so the FIRST match
    # wins the aggregation across several credentials.
    it 'ranks training worst-first' do
      expect(described_class::TRAINING_SEVERITY).to eq(
        [described_class::TRAINING_USED, described_class::TRAINING_UNSPECIFIED,
         described_class::TRAINING_EXCLUDED]
      )
    end

    it 'ranks retention worst-first, with unlimited above unspecified' do
      expect(described_class::RETENTION_SEVERITY).to eq(
        [described_class::RETENTION_UNLIMITED, described_class::RETENTION_UNSPECIFIED,
         described_class::RETENTION_LIMITED, described_class::RETENTION_NONE]
      )
    end

    it 'ranks sub-processors worst-first, undisclosed above unspecified' do
      expect(described_class::SUBPROCESSORS_SEVERITY).to eq(
        [described_class::SUBPROCESSORS_UNDISCLOSED, described_class::SUBPROCESSORS_UNSPECIFIED,
         described_class::SUBPROCESSORS_DISCLOSED]
      )
    end

    # A value missing from its severity order would drop out of every
    # aggregation silently: `find` returns nil and the card shows nothing.
    it 'covers every declared value in all three orders' do
      expect(described_class::TRAINING_SEVERITY).to match_array(described_class::TRAINING_USAGES)
      expect(described_class::RETENTION_SEVERITY).to match_array(described_class::RETENTION_POLICIES)
      expect(described_class::SUBPROCESSORS_SEVERITY)
        .to match_array(described_class::SUBPROCESSORS_DISCLOSURES)
    end
  end

  describe 'supporting documents' do
    it 'links documents through the join table' do
      contract = create(:ai_credential_contract)
      document = create(:ai_credential_document, ai_credential: contract.ai_credential)

      contract.documents << document

      expect(contract.reload.documents).to contain_exactly(document)
    end

    it 'refuses the same document twice' do
      contract = create(:ai_credential_contract)
      document = create(:ai_credential_document, ai_credential: contract.ai_credential)
      contract.documents << document

      duplicate = AiCredentialContractDocument.new(ai_credential_contract: contract,
                                                   ai_credential_document: document)

      expect(duplicate).not_to be_valid
    end
  end
end

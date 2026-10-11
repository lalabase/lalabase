# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent gate (plan §4.3, tests 5/6/8). The gate raises only for calls
# that are BOTH quota-relevant (billed on an included_in_quota system credential)
# AND over the hard limit. BYOK and non-metered usage are never gated. The
# fail-closed hierarchy (AiDisabled before Quota) is enforced by the Factory, which
# runs the opt-in gate first — covered here end-to-end.
RSpec.describe Lalabase::Llm::Gate do
  # budget 10 + buffer 5 → hard limit 15.
  let(:organisation) do
    create(:organisation, ai_quota_credits_override: 10, ai_quota_buffer_override: 5)
  end
  let!(:credential) { create(:ai_credential, :active, provider: 'openai', included_in_quota: true) }

  before { Rails.cache.clear }

  def book(credits, credential: self.credential)
    AiUsage.create!(organisation: organisation, provider: 'openai',
                    ai_credential: credential, credits_used: credits, used_at: Time.current)
  end

  describe '.ensure_within_quota!' do
    # Since P0 the seam gate takes the RESOLVED credential (the one the Factory
    # routed to), not a provider name — nil means BYOK.
    it 'raises QuotaExceededError when a quota-relevant org is over the hard limit' do
      book(20)
      expect { described_class.ensure_within_quota!(organisation, credential: credential) }
        .to raise_error(Lalabase::Llm::QuotaExceededError)
    end

    it 'does not raise while inside the grace zone' do
      book(12)
      expect { described_class.ensure_within_quota!(organisation, credential: credential) }
        .not_to raise_error
    end

    it 'does not raise for a non-metered system credential (test 8)' do
      non_metered = create(:ai_credential, :not_metered, provider: 'openai', active: false)
      book(50, credential: non_metered)
      expect { described_class.ensure_within_quota!(organisation, credential: non_metered) }
        .not_to raise_error
    end

    it 'does not raise for a BYOK call (nil credential), even over the limit (test 6)' do
      book(50)
      expect { described_class.ensure_within_quota!(organisation, credential: nil) }
        .not_to raise_error
    end

    # P0 regression: the gate judges the credential it is GIVEN. With two
    # credentials of the same provider in service (packages), re-resolving by
    # name would judge the active one — here metered — and wrongly block a call
    # that runs on the non-metered credential.
    it 'judges the given credential, not the provider-active one' do
      non_metered = create(:ai_credential, :not_metered, provider: 'openai', active: false)
      book(50)
      expect { described_class.ensure_within_quota!(organisation, credential: non_metered) }
        .not_to raise_error
      expect { described_class.ensure_within_quota!(organisation, credential: credential) }
        .to raise_error(Lalabase::Llm::QuotaExceededError)
    end
  end

  it 'stays inert for a BYOK org via the name-based pre-check (test 6)' do
    organisation.update!(ai_access_token: 'sk-org-own-key-123456789')
    book(50)
    expect(described_class.exhausted?(organisation, 'openai')).to be(false)
  end

  # Regression (review 2026-07-12): chat and embeddings have SEPARATE BYOK columns,
  # so the PRE-CHECK (`exhausted?`, no built provider) must judge BYOK per `kind` —
  # mirroring Factory's routing. Otherwise a mixed config gates (or frees) the
  # wrong call against the shared quota.
  describe 'per-kind BYOK (chat vs embeddings route independently)' do
    it 'does NOT gate an embedding call when the org has its OWN embedding key' do
      organisation.update!(embedding_provider: 'openai', embedding_access_token: 'sk-own-emb-123456')
      book(50)
      expect(described_class.exhausted?(organisation, 'openai', kind: :embedding)).to be(false)
    end

    it 'DOES gate an embedding call on the system credential when only CHAT is BYOK' do
      organisation.update!(ai_access_token: 'sk-own-chat-123456') # chat BYOK, embeddings on system
      book(50)
      expect(described_class.exhausted?(organisation, 'openai', kind: :embedding)).to be(true)
    end
  end

  describe 'fail-closed hierarchy via the Factory (test 5)' do
    it 'raises AiDisabledError (not Quota) for an AI-off org, even over the limit' do
      book(50)
      organisation.update!(ai_enabled: false)
      expect { Lalabase::Llm::Factory.for_chat(organisation) }
        .to raise_error(Lalabase::Llm::AiDisabledError)
    end

    it 'raises QuotaExceededError from for_chat for an over-limit quota org' do
      book(50)
      expect { Lalabase::Llm::Factory.for_chat(organisation) }
        .to raise_error(Lalabase::Llm::QuotaExceededError)
    end
  end
end

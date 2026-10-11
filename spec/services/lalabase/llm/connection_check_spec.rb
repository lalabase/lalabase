# frozen_string_literal: true

# What: Unit spec for Lalabase::Llm::ConnectionCheck — the org-side connection probe
#   (doc/ki_bereich_navigation_plan.md S7, decision E3, gaps L6/L10).
# Type: Service spec — outcome classification, gate behaviour, persistence.
# Why (philosophy): The version this replaces answered the wrong question twice and
#   remembered nothing. It ran through the GATED seam, so it refused the organisation
#   that was configuring itself (AI still off) and the one whose quota was gone —
#   neither of which is a statement about the access. And its result lived exactly as
#   long as one flash, which is why the hub card could not report a broken access at all.
#   Both halves are invisible in a happy-path test, so they are what this file is about.
# Contract: probes GATE-FREE; classifies into exactly four outcomes; stores ok/failed
#   plus a timestamp on the organisation and NEVER the provider's error text.

require 'rails_helper'

RSpec.describe Lalabase::Llm::ConnectionCheck do
  let(:organisation) { create(:organisation, :ai_disabled) }

  # instance_double verifies the method really exists — a probe stubbed on a name the
  # providers no longer carry would make every example here vacuously green.
  def stub_probe(answer)
    probe = instance_double(Lalabase::Llm::OpenAiProvider)
    allow(probe).to receive(:connectivity_check) { answer.is_a?(Exception) ? raise(answer) : answer }
    allow(Lalabase::Llm::Factory).to receive(:chat_probe).with(organisation).and_return(probe)
  end

  describe 'the gates it deliberately does not run through (L6)' do
    # ⚠️ This service can only be held to WHICH SEAM it calls, never to whether that
    # seam is gated — #stub_probe replaces the seam, so a gate re-added inside
    # Factory.chat_probe is invisible from here. Measured, not assumed: with
    # ensure_ai_enabled! put back into .chat_probe, every example in this file stayed
    # green. The gate-free property itself is pinned where it lives, on the real seam,
    # in spec/services/lalabase/llm/factory_spec.rb (".chat_probe (the diagnostic
    # exception)").
    it 'takes the gate-free seam rather than the gated one' do
      allow(Lalabase::Llm::Factory).to receive(:for_chat)
      stub_probe(true)

      described_class.call(organisation: organisation)

      expect(Lalabase::Llm::Factory).to have_received(:chat_probe).with(organisation)
      expect(Lalabase::Llm::Factory).not_to have_received(:for_chat)
    end
  end

  describe 'the four outcomes' do
    it 'reports :ok when the provider answers' do
      stub_probe(true)

      expect(described_class.call(organisation: organisation)).to have_attributes(outcome: :ok, ok?: true)
    end

    # Kept apart from :error on purpose: the request SUCCEEDED and came back empty,
    # which points at a key without model access rather than at a wrong key.
    it 'reports :no_models when the request went through but returned nothing' do
      stub_probe(false)

      expect(described_class.call(organisation: organisation)).to have_attributes(outcome: :no_models, ok?: false)
    end

    it 'reports :missing_credential when no access resolves at all' do
      allow(Lalabase::Llm::Factory).to receive(:chat_probe)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'none')

      expect(described_class.call(organisation: organisation).outcome).to eq(:missing_credential)
    end

    it 'reports :error for anything else and does not raise' do
      stub_probe(Lalabase::Llm::Provider::AuthError.new('401 bad key'))

      expect { described_class.call(organisation: organisation) }.not_to raise_error
      expect(described_class.call(organisation: organisation).outcome).to eq(:error)
    end

    # Breadth is the point: a malformed service-account JSON surfaces as a raw parser
    # error, and a hand-typed endpoint can fail in ways no provider maps. A diagnostic
    # button that 500s on a broken access is worse than no button.
    it 'survives an error no provider maps' do
      stub_probe(ArgumentError.new('unexpected token'))

      expect(described_class.call(organisation: organisation).outcome).to eq(:error)
    end

    it 'names the resolved provider so the flash can label it' do
      organisation.update!(ai_provider: 'anthropic')
      stub_probe(true)

      expect(described_class.call(organisation: organisation).provider_name).to eq('anthropic')
    end
  end

  describe 'what it writes (L10)' do
    it 'stores the ok verdict and when it was reached' do
      stub_probe(true)

      before = Time.current
      described_class.call(organisation: organisation)

      expect(organisation.reload.ai_connection_status).to eq(Organisation::AI_CONNECTION_OK)
      # The timestamp is what "zuletzt geprüft am …" renders, so it has to be THIS
      # check's time — a column that merely stopped being nil would satisfy a presence
      # assertion while reporting a check from last year.
      expect(organisation.ai_connection_checked_at).to be_between(before, Time.current)
    end

    it 'stores the failed verdict for every non-ok outcome' do
      stub_probe(false)
      described_class.call(organisation: organisation)
      expect(organisation.reload.ai_connection_failed?).to be(true)

      stub_probe(Lalabase::Llm::Provider::AuthError.new('401'))
      described_class.call(organisation: organisation)
      expect(organisation.reload.ai_connection_failed?).to be(true)
    end

    # ⚠️ The one rule that is not about correctness but about what ends up in a column
    # the hub renders. A provider error can carry the endpoint, a request id and — on a
    # misconfigured openai_compatible endpoint — whatever a stranger's server chose to
    # write. The reason belongs in a flash, read once; the column holds a verdict.
    it 'never stores the provider error text, only the verdict' do
      stub_probe(Lalabase::Llm::Provider::AuthError.new('401 from https://evil.example/v1 — key sk-abc'))

      result = described_class.call(organisation: organisation)

      expect(result.message).to include('evil.example')
      expect(organisation.reload.ai_connection_status).to eq(Organisation::AI_CONNECTION_FAILED)
      expect(Organisation.column_names.grep(/ai_connection/).map { |c| organisation[c].to_s })
        .to all(satisfy { |value| value.exclude?('evil.example') && value.exclude?('sk-abc') })
    end

    # A verdict recorded from a diagnostic must not be able to be blocked by an
    # unrelated column being out of shape — that would report green while the hub
    # stayed silent, which is the one combination nobody could debug.
    it 'records even when the organisation would not pass validation' do
      stub_probe(true)
      organisation.update_columns(name: nil)

      described_class.call(organisation: organisation)

      expect(organisation.reload.ai_connection_ok?).to be(true)
    end

    # The protocol records DECISIONS somebody made about the processing. A probe changes
    # nothing, and anyone may press the button repeatedly — rows here would bury the
    # entries the page exists for.
    it 'writes no protocol row' do
      stub_probe(true)

      expect { described_class.call(organisation: organisation) }
        .not_to(change { ActsAsTenant.with_tenant(organisation) { Activity.count } })
    end
  end
end

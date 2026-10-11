# frozen_string_literal: true

# What: Unit spec for Actors::RemoveAiConfiguration — "Zugang entfernen"
#   (doc/ki_bereich_navigation_plan.md, decision E2 Weg A with the condition from E2a).
# Type: Actor spec — what a removal clears, what it must NOT clear, and its audit row.
# Why (philosophy): This actor exists because its sibling refuses to remove a key by
#   omission. Two things about it are easy to get wrong and invisible afterwards: it must
#   clear ENOUGH (a stored token keeps Factory#resolve_credentials on the BYOK branch, so
#   a half-removal leaves the organisation with no way back to the system credential),
#   and it must clear NO MORE than that (dropping ai_provider would silently move an
#   Anthropic organisation onto the openai default — a processor change nobody asked for
#   and nothing on screen would state).
# Contract: clears token, organisation id, endpoint, model and the connection verdict;
#   keeps ai_provider; writes exactly one audit row, without the secret, and only when
#   something actually moved.

require 'rails_helper'

RSpec.describe Actors::RemoveAiConfiguration do
  let(:user) { create(:user) }
  let(:organisation) do
    create(:organisation,
           ai_provider: 'openai_compatible',
           ai_access_token: 'key-123',
           ai_organization_id: 'org-1',
           ai_api_base: 'https://api.mistral.ai/v1',
           preferred_chat_model: 'mistral-large-3',
           ai_connection_status: Organisation::AI_CONNECTION_OK,
           ai_connection_checked_at: 1.day.ago)
  end

  def remove
    described_class.call(organisation: organisation, current_user: user)
  end

  def activities
    ActsAsTenant.with_tenant(organisation) do
      Activity.where(action: AiConfigurationAudit::ACTION).order(:created_at).to_a
    end
  end

  # The ambient tenant is what a REQUEST provides, and without it the fanout example
  # below measures nothing: the actor's own with_tenant block is gone by the time its
  # transaction commits, so the commit callback would run with current_tenant = nil,
  # OutboxEvent (acts_as_tenant) would raise NoTenantSet, and Rails swallows exceptions
  # raised inside after_commit — the fanout would then be prevented by an ERROR rather
  # than by the skip flags. Same trap the sibling actor's spec documents.
  def remove_under_tenant
    ActsAsTenant.with_tenant(organisation) { remove }
  end

  describe 'what it clears' do
    it 'removes the secret and everything addressed with it' do
      expect(remove).to be_success

      expect(organisation.reload).to have_attributes(
        ai_access_token: nil, ai_organization_id: nil,
        ai_api_base: nil, preferred_chat_model: nil
      )
    end

    # The point of the whole action: with a token stored, Factory#resolve_credentials
    # takes the BYOK branch and has_valid_ai_configuration? never falls back. Asserting
    # the resulting BEHAVIOUR rather than the column, because the column is only the
    # means — a future change that keeps the column empty but leaves the org on BYOK
    # would still be the defect this exists to prevent.
    it 'puts the organisation back on the system credential path' do
      expect(organisation.has_own_ai_credentials?('openai_compatible')).to be(true)

      remove

      expect(organisation.reload.has_own_ai_credentials?('openai_compatible')).to be(false)
    end

    # The verdict describes an access that no longer exists. Left behind, the hub card
    # would keep vouching for something that is gone.
    it 'drops the connection verdict along with the access' do
      remove

      expect(organisation.reload).to have_attributes(ai_connection_status: nil, ai_connection_checked_at: nil)
      expect(organisation.ai_connection_never_tested?).to be(true)
    end

    # ⚠️ The deliberate exception. ai_provider is not part of the secret, it is the
    # answer to "which system credential should serve us" — and Factory#chat_provider_name
    # falls back to openai when it is blank, so clearing it would move this organisation
    # from Mistral to OpenAI as a side effect of handing back a key.
    it 'keeps the chosen provider' do
      remove

      expect(organisation.reload.ai_provider).to eq('openai_compatible')
    end
  end

  describe 'the audit row' do
    it 'files one row under the configuration verb' do
      expect { remove }.to change { activities.size }.by(1)

      expect(activities.last.parameters).to include(
        'from_provider' => 'openai_compatible',
        'to_provider' => 'openai_compatible',
        'from_api_base' => 'https://api.mistral.ai/v1',
        'to_api_base' => nil,
        'own_token_present' => false,
        'token_rotated' => true
      )
    end

    # An audit row carrying the secret would be a second, unencrypted copy of it in a
    # table built to be read.
    it 'never carries the key itself' do
      remove

      expect(activities.last.parameters.values.map(&:to_s)).not_to include('key-123')
    end

    # "Nothing happened" in an audit trail cannot be told apart from a real entry
    # afterwards, so a removal on an organisation that has nothing to remove writes
    # nothing at all.
    it 'writes no row when there was nothing to remove' do
      bare = create(:organisation, ai_provider: 'openai')

      expect do
        described_class.call(organisation: bare, current_user: user)
      end.not_to(change { ActsAsTenant.with_tenant(bare) { Activity.count } })
    end

    # An Activity is not a quiet row: after_create_commit reaches OutboxEvent →
    # FanoutService, and derive_event_type falls back to system_message for an unknown
    # key. Unthrottled, removing a key would mail the whole organisation.
    it 'does not fan out a notification' do
      expect { remove_under_tenant }
        .not_to(change { ActsAsTenant.with_tenant(organisation) { OutboxEvent.count } })
    end
  end

  # An escape hatch with conditions is a trap. Every other write in this area may refuse;
  # this one is what those refusals are measured against.
  it 'succeeds even for a configuration the save actor would reject' do
    organisation.update_columns(ai_provider: 'openai_compatible', ai_api_base: nil, preferred_chat_model: nil)

    expect(remove).to be_success
    expect(organisation.reload.ai_access_token).to be_nil
  end
end

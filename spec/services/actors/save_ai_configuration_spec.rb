# frozen_string_literal: true

# What: Unit spec for Actors::SaveAiConfiguration — the write behind "Eigene
#   Konfiguration" (doc/ki_bereich_navigation_plan.md S7, E6-A).
# Type: Actor spec — write semantics, domain failures, audit row.
# Why (philosophy): This actor replaces an inline controller update that carried three
#   of the plan's thirteen gaps. Most of what matters here is what the write must NOT
#   do: never drop a stored token as a side effect (L3/E2), never store a combination
#   that leaves the organisation broken (L7), and never let a kept key be repointed at
#   an address its owner did not choose. All three are invisible in a happy-path test,
#   so they are what this file is mostly about.
# Contract: writes only the five own-access columns; an ABSENT field keeps its stored
#   value while a BLANK one clears it (the token excepted, since it is never echoed
#   back); refuses an incomplete combination, an unusable key shape, a non-public or
#   non-https endpoint, and any provider/endpoint move that does not re-supply the key;
#   writes exactly one audit row, and only when something actually moved.

require 'rails_helper'

RSpec.describe Actors::SaveAiConfiguration do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:openai_key) { "sk-#{'x' * 30}" }

  def save(params)
    described_class.call(organisation: organisation, params: params, current_user: user)
  end

  def activities
    ActsAsTenant.with_tenant(organisation) do
      Activity.where(action: described_class::ACTIVITY_ACTION).order(:created_at).to_a
    end
  end

  def outbox_count
    ActsAsTenant.with_tenant(organisation) { OutboxEvent.count }
  end

  # ⚠️ The ambient tenant is what a REQUEST provides, and without it the fanout examples
  # below measure NOTHING. The actor's own `with_tenant` block is long gone by the time
  # its transaction commits, so the commit callback runs with current_tenant = nil,
  # OutboxEvent (acts_as_tenant) raises NoTenantSet, and Rails swallows exceptions raised
  # inside after_commit. The fanout was then prevented by an ERROR instead of by the
  # flags — measured: with both flags removed, no OutboxEvent appeared and all examples
  # stayed green. This mirrors what Organisations::BaseController sets up for every real
  # call.
  def save_under_tenant(params)
    ActsAsTenant.with_tenant(organisation) { save(params) }
  end

  describe 'the write itself' do
    it 'stores a complete OpenAI access' do
      result = save(ai_provider: 'openai', ai_access_token: openai_key, ai_organization_id: 'org-1')

      expect(result).to be_success
      expect(organisation.reload).to have_attributes(ai_provider: 'openai', ai_organization_id: 'org-1')
    end

    # L7, the reason REQUIRED_FIELDS is a table rather than one check: an
    # openai_compatible access needs endpoint AND model on top of the key, because
    # Organisation#own_ai_token_usable? demands both. Storing key-only would look
    # saved and leave the organisation counting as not configured.
    it 'refuses an openai_compatible access without endpoint and model' do
      result = save(ai_provider: 'openai_compatible', ai_access_token: 'key-123')

      expect(result).not_to be_success
      expect(result.errors.join).to include('Endpunkt-URL').and include('Modellname')
      expect(organisation.reload.ai_provider).not_to eq('openai_compatible')
    end

    it 'stores an openai_compatible access once endpoint and model are there' do
      result = save(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                    ai_api_base: 'https://api.mistral.ai/v1', preferred_chat_model: 'mistral-large-3')

      expect(result).to be_success
      expect(organisation.reload).to have_attributes(ai_api_base: 'https://api.mistral.ai/v1',
                                                     preferred_chat_model: 'mistral-large-3')
    end

    it 'refuses a provider it does not know' do
      result = save(ai_provider: 'definitely-not-a-provider', ai_access_token: 'x')

      expect(result).not_to be_success
      expect(result.code).to eq(:unknown_provider)
    end
  end

  # The key SHAPE, asked before the write through the one owner of the rule
  # (Organisation#own_ai_token_usable?). Presence alone was not enough: BYOK is
  # terminal, so a key that does not fit its provider does not degrade the
  # configuration, it switches AI off while the form reports success.
  describe 'the key shape' do
    it 'refuses an OpenAI key that is not one' do
      result = save(ai_provider: 'openai', ai_access_token: 'nonsense')

      expect(result.code).to eq(:unusable_token)
      expect(organisation.reload.ai_access_token).to be_blank
    end

    # Vertex is service-account-only; an API key would silently use the GLOBAL
    # endpoint and void EU data residency.
    it 'refuses a Google token that is not a service-account JSON' do
      result = save(ai_provider: 'google', ai_access_token: 'not-a-service-account')

      expect(result.code).to eq(:unusable_token)
    end

    # The `else true` branch of own_ai_token_usable? is deliberate, not an oversight:
    # a guessed format that answers "no" would hide a working configuration.
    it 'accepts any non-empty Anthropic key, because no format is ours to assert' do
      expect(save(ai_provider: 'anthropic', ai_access_token: 'whatever-anthropic-issued')).to be_success
    end
  end

  # ⚠️ THE reason this actor exists in the shape it has (L3 / E2 Weg A). The method it
  # replaces wrote `ai_access_token: nil` whenever the form came back with system
  # credentials selected — one click, and a key most providers never show again was
  # gone, with no warning and no undo.
  describe 'the stored token' do
    before { organisation.update!(ai_provider: 'openai', ai_access_token: "sk-#{'y' * 30}") }

    it 'survives a save that sends it blank — a form field is empty because the secret is not echoed back' do
      result = nil

      expect { result = save(ai_provider: 'openai', ai_access_token: '') }
        .not_to(change { organisation.reload.ai_access_token })
      expect(result).to be_success
    end

    it 'is replaced when a new one is actually sent' do
      save(ai_provider: 'openai', ai_access_token: "sk-#{'z' * 30}")

      expect(organisation.reload.ai_access_token).to eq("sk-#{'z' * 30}")
    end

    # The completeness check reads what will BE stored, not what was sent. Without the
    # record already carrying the stored token, editing the model of an existing
    # openai_compatible access would be refused as "key missing" — the exact
    # combination E2 exists to allow.
    it 'counts towards completeness even when the form left it blank' do
      organisation.update!(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                           ai_api_base: 'https://api.mistral.ai/v1', preferred_chat_model: 'mistral-large-3')

      result = save(ai_provider: 'openai_compatible', ai_access_token: '',
                    ai_api_base: 'https://api.mistral.ai/v1', preferred_chat_model: 'mistral-small')

      expect(result).to be_success
      expect(organisation.reload.preferred_chat_model).to eq('mistral-small')
    end
  end

  # ⚠️ The half of E2-A that only becomes visible once the endpoint is settable, which
  # this actor is the first write path to make it (L7). Keeping a key is safe only while
  # the key keeps pointing where its owner pointed it: the UI renders it masked and
  # never echoes it, so moving provider or endpoint underneath it is a way to READ a key
  # the current admin never saw. OpenAiCompatibleProvider#client sends it as a bearer to
  # whatever uri_base the column holds.
  describe 'repointing a kept key' do
    before do
      organisation.update!(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                           ai_api_base: 'https://api.mistral.ai/v1', preferred_chat_model: 'mistral-large-3')
    end

    it 'refuses to move the endpoint while the key stays blank' do
      result = save(ai_provider: 'openai_compatible', ai_access_token: '',
                    ai_api_base: 'https://attacker.example/v1', preferred_chat_model: 'mistral-large-3')

      expect(result.code).to eq(:token_reentry_required)
      expect(organisation.reload.ai_api_base).to eq('https://api.mistral.ai/v1')
    end

    it 'refuses to move the provider while the key stays blank' do
      result = save(ai_provider: 'anthropic', ai_access_token: '')

      expect(result.code).to eq(:token_reentry_required)
      expect(organisation.reload.ai_provider).to eq('openai_compatible')
    end

    # Proof of possession, not rotation: re-supplying the key is what makes the move
    # a decision of somebody who has it.
    it 'allows the move once the key is supplied again' do
      result = save(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                    ai_api_base: 'https://api.eu.mistral.ai/v1', preferred_chat_model: 'mistral-large-3')

      expect(result).to be_success
      expect(organisation.reload.ai_api_base).to eq('https://api.eu.mistral.ai/v1')
    end

    # Nothing moved, so nothing is being redirected — editing the model of a running
    # access must not demand the key back.
    it 'does not demand the key for a change that moves neither provider nor endpoint' do
      expect(save(ai_provider: 'openai_compatible', ai_access_token: '',
                  ai_api_base: 'https://api.mistral.ai/v1', preferred_chat_model: 'mistral-small')).to be_success
    end
  end

  # The endpoint is a URL a customer types and the app then sends a decrypted key to.
  describe 'the endpoint address' do
    def save_endpoint(base)
      save(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
           ai_api_base: base, preferred_chat_model: 'mistral-large-3')
    end

    it 'refuses http, which would put the key on the wire in clear' do
      expect(save_endpoint('http://api.mistral.ai/v1').code).to eq(:api_base_not_https)
    end

    it 'refuses a loopback address' do
      expect(save_endpoint('https://127.0.0.1/v1').code).to eq(:api_base_not_public)
    end

    # Pinned as its own case because a URL is not one syntax: swapping hostname for
    # host does NOT break this example (IPAddr accepts the bracketed form too, measured),
    # so what it guards is the loopback rule itself, which does break the moment the
    # address check goes.
    it 'refuses an IPv6 loopback literal' do
      expect(save_endpoint('https://[::1]/v1').code).to eq(:api_base_not_public)
    end

    it 'refuses a private-network address' do
      expect(save_endpoint('https://10.0.0.5/v1').code).to eq(:api_base_not_public)
    end

    it 'refuses localhost by name, which no address check would catch' do
      expect(save_endpoint('https://localhost/v1').code).to eq(:api_base_not_public)
    end

    # Reported against the first version, which judged the spelling of a name: each of
    # these passed it, and the connection test then said which ports were open.
    {
      'https://localhost./v1' => 'the trailing dot names the same host',
      'https://redis.:6379/v1' => 'a short name of the server network',
      'https://localhost.attacker.example/v1' => 'a public name pointing at loopback',
      'https://awsmeta.attacker.example/v1' => 'a public name pointing at the metadata service'
    }.each do |endpoint, why|
      it "refuses #{endpoint} (#{why})" do
        resolve_names('redis' => ['192.168.0.1'], 'localhost.attacker.example' => ['127.0.0.1', '::1'],
                      'awsmeta.attacker.example' => ['169.254.169.254'])

        expect(save_endpoint(endpoint).code).to eq(:api_base_not_public)
        expect(organisation.reload.ai_api_base).to be_blank
      end
    end

    # Same answer as for an inward name: a different one would tell the caller which
    # internal names exist.
    it 'refuses a name that does not resolve, with the same answer' do
      Lalabase::PublicAddress.resolver = ->(_hostname) { raise SocketError, 'no such name' }

      expect(save_endpoint('https://nowhere.example/v1').code).to eq(:api_base_not_public)
    end

    it 'refuses something that is not a URL at all' do
      expect(save_endpoint('not a url').code).to eq(:api_base_not_https)
    end

    it 'accepts a public https endpoint' do
      expect(save_endpoint('https://api.mistral.ai/v1')).to be_success
    end
  end

  # Three states, not two. The middle one is what the old #update got wrong in the
  # other direction, and what a "save one field" request depends on.
  describe 'absent versus blank fields' do
    before do
      organisation.update!(ai_provider: 'openai', ai_access_token: "sk-#{'y' * 30}",
                           preferred_chat_model: 'gpt-4o', ai_organization_id: 'org-keep')
    end

    # ⚠️ preferred_chat_model is load-bearing: Factory#resolve_credentials feeds the
    # BYOK chat model solely from it. A save that never mentioned it used to clear it.
    it 'keeps a column the params do not mention' do
      expect(save(ai_provider: 'openai')).to be_success
      expect(organisation.reload).to have_attributes(preferred_chat_model: 'gpt-4o',
                                                     ai_organization_id: 'org-keep')
    end

    # Without this, an organisation id or an endpoint could never be removed at all,
    # because the only other way to clear a column is omitting it.
    it 'clears a column the params send empty' do
      expect(save(ai_provider: 'openai', ai_organization_id: '')).to be_success
      expect(organisation.reload.ai_organization_id).to be_nil
    end
  end

  # ⚠️ The five literals that walked straight through the first version of the guard.
  # IPAddr#loopback?/#private?/#link_local? judge the address AS WRITTEN, so an
  # IPv4-mapped IPv6 literal is none of them — and the second entry below is the cloud
  # metadata endpoint, which OpenAiCompatibleProvider would receive the decrypted BYOK
  # key for, as a Bearer token, handing its answer back into the app. The unspecified
  # addresses are the other half: neither loopback nor private, and "this host" to every
  # connecting socket.
  describe 'the endpoint address, in every notation of the same destination' do
    ['https://[::ffff:127.0.0.1]/v1', 'https://[0:0:0:0:0:ffff:7f00:1]/v1',
     'https://[::ffff:169.254.169.254]/v1', 'https://0.0.0.0/v1', 'https://[::]/v1',
     # ── The SECOND round of the same mistake (review of PR #512). IPAddr refuses to
     # parse these four, the resolver does not: measured, getaddrinfo answers
     # 127.0.0.1 / 127.0.0.1 / 127.0.0.1 / 10.0.0.5 — and all four were stored. They
     # are not the residual DNS gap the guard admits to; that one is about a NAME whose
     # record moves. This is the same literal address, spelled differently, i.e. exactly
     # the direct route the guard claims to remove.
     'https://2130706433/v1', 'https://127.1/v1', 'https://0x7f.0.0.1/v1',
     'https://0xa.0.0.5/v1',
     # Carrier-grade NAT: parses fine, and no IPAddr predicate reports it.
     'https://100.64.0.1/v1',
     # The control. If this one ever stops failing, nothing below it means anything.
     'https://127.0.0.1/v1'].each do |endpoint|
      it "refuses #{endpoint}" do
        result = save(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                      ai_api_base: endpoint, preferred_chat_model: 'm')

        expect(result).not_to be_success
        expect(organisation.reload.ai_api_base).to be_blank
      end
    end

    # The other side of the same predicate: a public address must still pass, or the
    # guard would be "refuse everything", which no example above could tell apart.
    ['https://52.1.2.3/v1', 'https://[2606:4700:4700::1111]/v1', 'https://api.mistral.ai/v1'].each do |endpoint|
      it "allows #{endpoint}" do
        result = save(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                      ai_api_base: endpoint, preferred_chat_model: 'm')

        expect(result).to be_success
      end
    end
  end

  # The fifth verb has to be in the LIST, not only at the write site: the protocol page
  # filters on AiProtocolActions::ALL, so a verb missing there produces rows nobody can
  # see — on the page built to show them.
  it 'writes a verb the protocol page actually looks for' do
    expect(AiProtocolActions::ALL).to include(described_class::ACTIVITY_ACTION)
  end

  describe 'the audit row (E5/L13, third write site)' do
    it 'records the provider change with both sides' do
      expect { save(ai_provider: 'anthropic', ai_access_token: "sk-ant-#{'a' * 20}") }
        .to change { activities.size }.by(1)

      expect(activities.last.parameters).to include('from_provider' => 'openai', 'to_provider' => 'anthropic')
    end

    # "Where did our data start going, and when" is the question asked after an
    # incident. For an openai_compatible access the provider does not move and the URL
    # is the whole difference, so a payload naming only the provider cannot answer it.
    it 'records the endpoint move with both sides' do
      organisation.update!(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
                           ai_api_base: 'https://api.mistral.ai/v1', preferred_chat_model: 'mistral-large-3')

      save(ai_provider: 'openai_compatible', ai_access_token: 'key-123',
           ai_api_base: 'https://api.eu.mistral.ai/v1', preferred_chat_model: 'mistral-large-3')

      expect(activities.last.parameters).to include('from_api_base' => 'https://api.mistral.ai/v1',
                                                    'to_api_base' => 'https://api.eu.mistral.ai/v1')
    end

    # own_token_present is true on BOTH sides of a rotation, so without its own flag a
    # key swap is indistinguishable from a write that touched something else.
    it 'tells a key rotation apart from a change that leaves the key alone' do
      organisation.update!(ai_provider: 'openai', ai_access_token: openai_key)

      save(ai_provider: 'openai', ai_access_token: "sk-#{'r' * 30}")
      expect(activities.last.parameters).to include('token_rotated' => true)

      save(ai_provider: 'openai', ai_access_token: '', ai_organization_id: 'org-2')
      expect(activities.last.parameters).to include('token_rotated' => false,
                                                    'to_organization_id' => 'org-2')
    end

    # What the row lock buys, testable without two connections: the audit row's "from"
    # side must describe the row this write actually replaced, not the copy the caller
    # happened to be holding. update_all moves the row behind the in-memory object
    # exactly the way a second admin's request would.
    it 'names the state it really replaced, not the one the caller was holding' do
      organisation.update!(ai_provider: 'openai', ai_access_token: "sk-#{'y' * 30}")
      Organisation.where(id: organisation.id).update_all(ai_provider: 'anthropic')

      save(ai_provider: 'openai', ai_access_token: "sk-#{'n' * 30}")

      expect(activities.last.parameters).to include('from_provider' => 'anthropic', 'to_provider' => 'openai')
    end

    # Same rule as the two existing write sites: an entry for a write that moved
    # nothing cannot be told apart from a real one afterwards.
    it 'writes nothing when the save changes nothing' do
      organisation.update!(ai_provider: 'openai', ai_access_token: "sk-#{'q' * 30}")

      expect { save(ai_provider: 'openai') }.not_to(change { activities.size })
    end

    # The token is a secret. An audit table is built to be READ — putting the key in
    # its payload would create a second, unencrypted copy of it.
    it 'never puts the token into the payload' do
      save(ai_provider: 'openai', ai_access_token: openai_key)

      expect(activities.last.parameters.to_json).not_to include(openai_key)
      expect(activities.last.parameters).to include('own_token_present' => true)
    end

    # An Activity is not a quiet audit row: after_create_commit reaches OutboxEvent →
    # OutboxConsumeJob → FanoutService, and derive_event_type falls back to
    # SYSTEM_MESSAGE for an unknown key rather than to nil. Without the flags a provider
    # change would fan a generic system notification, e-mails included, across the org.
    it 'notifies nobody' do
      expect { save_under_tenant(ai_provider: 'anthropic', ai_access_token: "sk-ant-#{'b' * 20}") }
        .not_to(change { outbox_count })
    end

    # The premise of the example above, measured rather than assumed: the same row
    # without the flags DOES fan out. Without this control, "notifies nobody" would pass
    # just as happily if the chain had never been wired up at all.
    it 'would notify without the flags — which is what the flags are for' do
      expect do
        ActsAsTenant.with_tenant(organisation) do
          Activity.create!(organisation: organisation, actor: user, trackable: organisation,
                           action: described_class::ACTIVITY_ACTION)
        end
      end.to change { outbox_count }.by(1)
    end

    # acts_as_tenant OVERWRITES the passed organisation from current_tenant in a
    # before_validation, so an audit row whose mandant depends on ambient state is not
    # an audit row. Asserted by reading INSIDE the tenant.
    it 'files the row under the organisation it is about' do
      save(ai_provider: 'anthropic', ai_access_token: "sk-ant-#{'c' * 20}")

      expect(activities.last.organisation_id).to eq(organisation.id)
    end
  end

  # The actor writes its own five columns and nothing else — a params hash from a form
  # must not be able to reach anything beyond them.
  it 'ignores attributes outside its own five columns' do
    expect { save(ai_provider: 'openai', ai_access_token: openai_key, ai_enabled: true, name: 'Gekapert') }
      .not_to(change { organisation.reload.slice('name', 'ai_enabled') })
  end
end

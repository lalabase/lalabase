# frozen_string_literal: true

require 'rails_helper'

# What: find_people and get_person reached through Tools::Runner, with the real :assistant
#       set and a stubbed provider (People S3).
# Why:  The two tools are only as safe as their wiring: offered to the model in the
#       assistant's set, refused by the Runner on a thread without an asker before they
#       run, and their person citations land in the answer's citations, which is what the
#       answer's rights gate (MessageComponent#redacted?) reads.
RSpec.describe 'People tools through the Runner (People S3)', :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:chat) { build(:chat, organisation: organisation).tap(&:save!) }
  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider) }
  let(:messages) do
    [{ role: 'system', content: 'sys' }, { role: 'user', content: 'Wer ist bei Nordlicht technischer Ansprechpartner?' }]
  end
  let(:viewer) do
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end
  let!(:contact) do
    create(:person, organisation: organisation, name: 'Doris Dienstleister', function: 'Technischer Ansprechpartner',
                    company: 'Nordlicht GmbH', phone: '+49 30 1234567')
  end
  let(:offered) { [] }

  before do
    replies = [
      tool_call([{ id: 't1', name: 'find_people', args: { 'query' => 'technisch' } }]),
      tool_call([{ id: 't2', name: 'get_person', args: { 'id' => "person:#{contact.id}" } }]),
      { content: 'Doris Dienstleister, Telefon +49 30 1234567.', tool_calls: nil, stop_reason: 'stop',
        model_used: 'gpt-4o-mini', token_usage: { total_tokens: 10 } }
    ]
    allow(provider).to receive(:chat) do |tools:, **|
      offered << tools.pluck(:name)
      replies.shift
    end
  end

  def tool_call(calls)
    { content: '', tool_calls: calls, stop_reason: 'tool_calls', model_used: 'gpt-4o-mini',
      token_usage: { total_tokens: 20 } }
  end

  def run(asker:)
    runner = Lalabase::Tools::Runner.new(chat: chat, provider: provider, messages: messages, asker: asker)
    runner.call { |_chunk| nil }
    runner
  end

  it 'offers both tools to the model, looks the person up and cites it with the people area' do
    runner = run(asker: viewer)

    expect(offered.first).to include('find_people', 'get_person')
    expect(runner.tool_calls_log.pluck(:tool)).to eq(%w[find_people get_person])
    expect(runner.tool_calls_log.pluck(:succeeded)).to eq([true, true])
    expect(runner.citations).to eq([{ type: 'person', area: 'people', id: contact.id, name: 'Doris Dienstleister' }])
    expect(Lalabase::Citations.areas_of(runner.citations.map(&:deep_stringify_keys))).to eq([:people])
  end

  # A thread whose history has no asker: no person data, refused by the Runner itself.
  it 'refuses both tools on a thread without an asker, before they run' do
    allow(Lalabase::Tools::FindPeople).to receive(:execute).and_call_original
    allow(Lalabase::Tools::GetPerson).to receive(:execute).and_call_original

    runner = run(asker: nil)

    expect(runner.tool_calls_log.pluck(:succeeded)).to eq([false, false])
    expect(runner.tool_calls_log.pluck(:result_summary)).to all(include('no authenticated user'))
    expect(Lalabase::Tools::FindPeople).not_to have_received(:execute)
    expect(Lalabase::Tools::GetPerson).not_to have_received(:execute)
    expect(runner.citations).to eq([])
  end
end

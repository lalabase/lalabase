# frozen_string_literal: true

require 'rails_helper'

# What: the two AI features on a ticket read public comments only, "ask AI" reads the
#   project notes only for someone with the notes right, and the ticket's own text
#   travels in the user role, not in the system role.
# Why: every reader of the ticket sees the result, the summary on the ticket and the
#   AI answer as a public comment. Until 27.09.2026 the summary read every comment
#   and "ask AI" read the comments private to the asker plus all project notes, so a
#   private comment or a note could reach readers through the answer. The prompt
#   carried user-written text in the system role, where it outranks the instructions.
RSpec.describe 'Private comments in AI prompts', :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, content: 'Login is slow') }
  let(:asker) { create(:user) }
  let(:colleague) { create(:user) }
  let!(:ai_user) { create(:user, is_ai: true) }

  let(:provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai').tap do |provider|
      allow(provider).to receive(:chat).and_return(content: 'Answer', model_used: 'gpt-4o-mini',
                                                   token_usage: { total_tokens: 3 })
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
    Prosopite.pause do
      [asker, colleague].each { |user| create(:membership, user: user, organisation: organisation) }
      create(:post, ticket: ticket, user: colleague, content: 'Public finding: N+1 query')
      create(:post, ticket: ticket, user: colleague, content: 'Private to the asker', is_private: true,
                    visible_to_user: asker)
      create(:post, ticket: ticket, user: colleague, content: 'Private note to self', is_private: true)
      create(:note, project: project, organisation: organisation, title: 'Runbook', content: 'Restart the cache')
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def sent_messages
    messages = nil
    expect(provider).to have_received(:chat) { |**args| messages = args[:messages] }
    messages
  end

  def prompt_text
    sent_messages.pluck(:content).join("\n")
  end

  describe 'TicketSummaryService' do
    before do
      allow(organisation).to receive(:ai_available_for?).with(:ticket_summary)
                                                        .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(available: true))
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ticket_summary, organisation).and_return(provider)
      Prosopite.pause { TicketSummaryService.new(ticket: ticket, organisation: organisation, updater: asker).call }
    end

    it 'reads the public comments and no private one' do
      expect(prompt_text).to include('Public finding: N+1 query')
      expect(prompt_text).not_to include('Private to the asker', 'Private note to self')
    end
  end

  describe 'Actors::CreateAiPost' do
    def ask(notes_access:)
      Prosopite.pause do
        create(:project_permission, user: asker, project: project, tickets_access: :read_write,
                                    notes_access: notes_access)
        allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, organisation).and_return(provider)
        Actors::CreateAiPost.call(ticket: ticket, current_user: asker, organisation: organisation)
      end
    end

    it 'reads the public comments and none private, not even those to the asker' do
      ask(notes_access: :read_only)

      expect(prompt_text).to include('Public finding: N+1 query')
      expect(prompt_text).not_to include('Private to the asker', 'Private note to self')
    end

    it 'reads the project notes for an asker with the notes right' do
      ask(notes_access: :read_only)

      expect(prompt_text).to include('Restart the cache')
    end

    it 'leaves the notes out for an asker without it' do
      ask(notes_access: :no_access)

      expect(prompt_text).not_to include('Restart the cache')
    end

    # Ids are random UUIDs: an id order (find_each) shuffles the conversation.
    it 'passes the comments in the order they were written' do
      Prosopite.pause do
        create(:post, id: 'ffffffff-ffff-4fff-bfff-ffffffffffff', ticket: ticket, user: colleague,
                      content: 'Earlier remark', created_at: 2.hours.ago)
        create(:post, id: '00000000-0000-4000-8000-000000000000', ticket: ticket, user: colleague,
                      content: 'Later remark', created_at: 1.hour.ago)
      end

      ask(notes_access: :read_only)

      expect(prompt_text.index('Earlier remark')).to be < prompt_text.index('Later remark')
    end

    it 'sends the instructions as system and the ticket text as user' do
      ask(notes_access: :read_only)

      system, user = sent_messages
      expect(system[:role]).to eq('system')
      expect(system[:content]).not_to include('Login is slow', 'Public finding', 'Restart the cache')
      expect(user[:role]).to eq('user')
      expect(user[:content]).to include('Login is slow', 'Public finding: N+1 query', 'Restart the cache')
    end
  end
end

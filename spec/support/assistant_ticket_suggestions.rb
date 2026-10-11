# frozen_string_literal: true

RSpec.shared_context 'assistant ticket suggestions' do
  let(:organisation) { create(:organisation, assistant_enabled: true, ai_enabled: true, ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef') }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Planungsrunde', notes: 'Notizen: Rechnung senden.', transcript: 'Mitschrift: Angebot prüfen.') }
  let(:chat) { create(:chat, user: user, organisation: organisation, scope_references: [{ type: 'Meeting', id: meeting.id }]) }
  let(:provider) { double('provider', chat: { content: '[{"title":"Rechnung senden","description":"Bis Freitag erledigen."},{"title":"Angebot prüfen","description":"Konditionen prüfen."}]', token_usage: {}, model_used: 'test' }) }
  let(:access) { ProjectPermission.find_by!(user: user, project: project) }

  before do
    @previous_suggestion_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: project, meetings_access: 'read_write', tickets_access: 'read_write')
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_ticket_suggestions, organisation).and_return(provider)
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
    allow(Lalabase::QueryEmbedding).to receive(:embed).and_return(nil)
  end

  after { ActiveJob::Base.queue_adapter = @previous_suggestion_adapter }

  def in_org(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def start_run(instruction: 'Nur konkrete Aufgaben.', target: meeting, thread: chat)
    result = Actors::CreateChatpost.call(chat: thread, current_user: user,
                                         params: { content: instruction, ticket_suggestion_meeting_id: target.id })
    expect(result).to be_success
    result.resource.meeting_ticket_suggestion_run
  end

  def finish_run(run)
    payload = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |job| job['job_id'] == run.job_id }
    expect(payload).to be_present
    execute_suggestion_payload(payload)
    run.reload
  end

  def execute_suggestion_payload(payload)
    tenant = ActsAsTenant.current_tenant
    ActiveJob::Base.execute(payload)
  ensure
    ActsAsTenant.current_tenant = tenant
  end
end

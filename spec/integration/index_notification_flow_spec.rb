# frozen_string_literal: true

require 'rails_helper'

# Connected-block coverage for M9-5: the WHOLE path from an index outcome to a
# delivered email, plus the configurability round-trip. The unit specs cover the
# pieces (notifier, mailer, job→notifier wiring); these run the real chain
# IndexOutcomeNotifier → Notification → EmailDeliveryJob → NotificationMailer →
# ActionMailer delivery, so a break ANYWHERE in the seam turns red.
RSpec.describe 'Index-outcome notification flow' do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation, code_indexing_enabled: true) } # per-org beta feature on
  let(:project)      { create(:project, organisation: organisation) }
  # Connecting a repository takes project rights, and EmailDeliveryJob only mails
  # people who can still see the project (#660): a member with a permission.
  let(:connector) do
    create(:user, email: 'dev@example.com', active: true, organisation: organisation).tap do |user|
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: project, tickets_access: 'read_write')
      end
    end
  end
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/backend', connected_by_user: connector)
    end
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    repository
    clear_enqueued_jobs
    ActionMailer::Base.deliveries.clear
    allow(Notifications::BroadcastService).to receive(:new)
      .and_return(instance_double(Notifications::BroadcastService, broadcast_creation: nil))
  end
  after { ActsAsTenant.current_tenant = nil }

  # The performed jobs (EmailDeliveryJob / RepoReindexJob) reset the thread tenant
  # on exit, so re-establish it and materialise the result for assertions.
  def notifications_for(event_type, channel)
    ActsAsTenant.with_tenant(organisation) do
      Notification.where(recipient: connector, event_type: event_type, channel: channel).to_a
    end
  end

  describe 'completed → delivered email' do
    it 'delivers a mail to the connector whose subject names the repo (not "item")' do
      perform_enqueued_jobs do
        Notifications::IndexOutcomeNotifier.call(repository: repository, outcome: :completed)
      end

      mail = ActionMailer::Base.deliveries.last
      expect(mail).to be_present
      expect(mail.to).to eq(['dev@example.com'])
      # End-to-end guard for the "Code index ready: item" bug — the real delivery
      # path (EmailDeliveryJob's EMAIL_SUBJECT_TEMPLATES + extract_notifiable_title).
      expect(mail.subject).to include('acme/backend')
      expect(mail.subject).not_to include('item')
      expect(notifications_for('index_completed', 'email')).not_to be_empty
    end
  end

  describe 'configurability round-trip' do
    it 'delivers NO mail when the user disabled the email channel — but keeps the in_app notification' do
      NotificationPreference.create!(user: connector, event_type: 'index_completed',
                                     channel: 'email', frequency: 'never', enabled: false)

      perform_enqueued_jobs do
        Notifications::IndexOutcomeNotifier.call(repository: repository, outcome: :completed)
      end

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(notifications_for('index_completed', 'email')).to be_empty
      expect(notifications_for('index_completed', 'in_app')).not_to be_empty
    end
  end

  describe 'failed re-index → delivered failure email (full job chain)' do
    before do
      # Use REAL hex commit SHAs. Since #23, RepoReindexJob#valid_commit_sha?
      # (COMMIT_SHA_PATTERN = /\A[0-9a-f]{7,64}\z/) rejects a non-hex after_sha and
      # delegates to a full ProjectIndexerJob via perform_later instead of running
      # the incremental reindex — so a placeholder like 'head-sha' made
      # RepoReindexJob.perform_now return WITHOUT ever hitting the embed failure
      # this test mocks, and nothing raised. base only needs to be present, but
      # keep it hex for realism (webhooks always send hex object names).
      repository.project_index.update!(status: 'ready', last_indexed_commit: 'a' * 40)

      github = instance_double(Lalabase::Github::Client)
      allow(Lalabase::Github::Client).to receive(:new).and_return(github)
      allow(github).to receive(:changed_files)
        .and_return([{ filename: 'app/a.rb', previous_filename: nil, status: 'modified' }])
      cloner = instance_double(Lalabase::Indexer::GitCloner)
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)
      allow(cloner).to receive(:call).and_yield(Pathname.new('/tmp/fake-clone'))
      walker = instance_double(Lalabase::Indexer::Symbols::Walker)
      allow(Lalabase::Indexer::Symbols::Walker).to receive(:new).and_return(walker)
      allow(walker).to receive(:symbols_for).and_return(
        [{ symbol_type: 'class', name: 'A', qualified_name: 'A', file_path: 'app/a.rb',
           start_line: 1, end_line: 2, signature: 'class A; end', language: 'ruby', metadata: {} }]
      )
      embed = instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai',
                                                             default_embedding_model: 'm')
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed)
      allow(embed).to receive(:embed_batch).and_raise(StandardError, 'embed boom')
    end

    it 'a RepoReindexJob failure flows fail_index! → notifier(:failed) → delivered failure mail' do
      perform_enqueued_jobs do
        expect { RepoReindexJob.perform_now(repository, after_sha: 'b' * 40) }.to raise_error(StandardError)
      end

      mail = ActionMailer::Base.deliveries.last
      expect(mail).to be_present
      expect(mail.subject).to include('acme/backend')
      expect(notifications_for('index_failed', 'email')).not_to be_empty
    end
  end
end

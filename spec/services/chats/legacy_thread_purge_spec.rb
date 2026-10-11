# frozen_string_literal: true

require 'rails_helper'

# What: Chats::LegacyThreadPurge — deletes the chat threads from the shared era.
# Type: Service spec.
# Why:  This runs once against real production data and there is no undo. The tests
#       that matter most here are the ones about what SURVIVES: (1) org-wide
#       threads never were shared and stay; (2) an ORGS restriction
#       must not touch a foreign tenant; (3) a dry run reports the real numbers and
#       writes nothing, since it is the only preview an operator gets. Plus the
#       cascade: chatposts must go with their chat, never stay behind as orphans
#       (there is no foreign key that would complain).
RSpec.describe Chats::LegacyThreadPurge do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:asker) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # A foreign thread has to be created UNDER its own tenant: acts_as_tenant stamps
  # organisation_id from the current tenant, so passing `organisation:` alone would
  # quietly produce a second thread in the current organisation and the isolation
  # tests would pass without ever crossing a tenant boundary.
  # ⚠️ The project_id is written as a RAW COLUMN, and that is the state of this purge
  # after projekt_chat_abbau: the surface that produced these rows is gone, Chat has no
  # `project` association any more, and the model can no longer build one. The rows it
  # deletes are LEGACY rows, and the only honest way to fixture them is the way they
  # exist in the database. The purge itself stays until step 5 of that plan: it is the
  # tool that empties chats.project_id, and the migration that drops the column aborts
  # loudly while a row still carries one.
  def project_thread(org: organisation)
    own_project = project if org == organisation
    ActsAsTenant.with_tenant(org) do
      own_project ||= create(:project, organisation: org)
      chat = create(:chat, organisation: org)
      chat.update_column(:project_id, own_project.id)
      chat
    end
  end

  describe 'what it deletes' do
    it 'deletes project threads' do
      chat = project_thread

      expect { described_class.call }.to change(Chat, :count).by(-1)
      expect(Chat.where(id: chat.id)).to be_empty
    end

    it 'takes the chatposts with it instead of orphaning them' do
      chat = project_thread
      create(:chatpost, chat: chat, organisation: organisation, user: asker, content: 'Frage')

      described_class.call

      expect(Chatpost.where(chat_id: chat.id)).to be_empty
    end

    it 'crosses organisations, because a maintenance run is not tenant-scoped' do
      project_thread
      foreign = project_thread(org: other_organisation)

      described_class.call

      expect(Chat.unscoped.where(id: foreign.id)).to be_empty
    end
  end

  describe 'what it leaves alone' do
    # Org-wide threads (T3) have been private since they came into being, they do not
    # come from the shared era. They carry no project_id; `where.not(project_id: nil)` is
    # the boundary that leaves them out.
    it 'keeps org-wide threads, which never were shared' do
      chat = create(:chat, :org_thread, organisation: organisation, user: asker)

      described_class.call

      expect(chat.reload).to be_persisted
    end

    it 'leaves other organisations untouched when ORGS narrows the run' do
      mine = project_thread
      foreign = project_thread(org: other_organisation)

      described_class.call(organisation_ids: [organisation.id])

      expect(Chat.unscoped.where(id: foreign.id)).to be_present
      expect(Chat.unscoped.where(id: mine.id)).to be_empty
    end

    # An empty array reaching the sweep as "every organisation" is the one misreading
    # that cannot be undone, so it is refused rather than interpreted.
    it 'refuses an empty organisation list instead of reading it as all of them' do
      project_thread

      expect { described_class.call(organisation_ids: []) }.to raise_error(ArgumentError)
      expect(Chat.count).to eq(1)
    end
  end

  describe 'the dry run' do
    it 'writes nothing' do
      project_thread

      expect { described_class.call(dry_run: true) }.not_to change(Chat, :count)
    end

    it 'reports the numbers the real run will produce' do
      chat = project_thread
      create(:chatpost, chat: chat, organisation: organisation, user: asker, content: 'Frage')

      preview = described_class.call(dry_run: true)
      real = described_class.call

      expect(preview.threads).to eq(real.threads)
      expect(preview.posts).to eq(real.posts)
    end

    it 'names the affected organisations, so the operator sees whose data it is' do
      project_thread
      project_thread(org: other_organisation)

      result = described_class.call(dry_run: true)

      expect(result.per_organisation).to eq(organisation.id => 1, other_organisation.id => 1)
    end
  end
end

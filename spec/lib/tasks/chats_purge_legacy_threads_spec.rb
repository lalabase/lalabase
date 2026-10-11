# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake chats:purge_legacy_threads`, the deletion run for the threads from the
#       shared era.
# Type: Rake task spec.
# Why:  The service spec next to it checks WHAT gets deleted. Here is the logic that
#       only the task has and that decides WHAT the run is aimed at: resolving ORGS
#       and aborting on the switch INCLUDE_TICKET_THREADS, which has had no effect
#       since S4-T1. A typo
#       in ORGS that silently passes as "all organisations" would be the most expensive
#       mistake of this task. That is why the abort is pinned here and not only
#       commented. Plus the output, because it is the only preview an operator gets
#       before an irreversible run.
RSpec.describe 'chats:purge_legacy_threads' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('chats:purge_legacy_threads')
  end

  before { Rake::Task['chats:purge_legacy_threads'].reenable }

  after do
    ENV.delete('DRY_RUN')
    ENV.delete('ORGS')
    ENV.delete('INCLUDE_TICKET_THREADS')
  end

  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Raw column on purpose, same reason as in legacy_thread_purge_spec: since
  # projekt_chat_abbau no model can build a thread with a project. These are legacy
  # rows, and the task exists to remove them.
  def project_thread(org: organisation)
    own_project = project if org == organisation
    ActsAsTenant.with_tenant(org) do
      own_project ||= create(:project, organisation: org)
      chat = create(:chat, organisation: org)
      chat.update_column(:project_id, own_project.id)
      chat
    end
  end

  def run_task
    Rake::Task['chats:purge_legacy_threads'].invoke
  end

  describe 'ORGS' do
    it 'grenzt den Lauf auf die genannte Organisation ein' do
      mine = project_thread
      foreign = project_thread(org: other_organisation)
      ENV['ORGS'] = organisation.name

      expect { run_task }.to output(/1 Verlaeufe/).to_stdout

      expect(Chat.unscoped.where(id: mine.id)).to be_empty
      expect(Chat.unscoped.where(id: foreign.id)).to be_present
    end

    it 'nimmt auch die UUID' do
      mine = project_thread
      ENV['ORGS'] = organisation.id

      expect { run_task }.to output(/1 Verlaeufe/).to_stdout
      expect(Chat.unscoped.where(id: mine.id)).to be_empty
    end

    # The expensive case: a name that does not exist must NOT pass as "all".
    it 'bricht bei einer unbekannten Organisation ab, statt alles zu loeschen' do
      project_thread
      ENV['ORGS'] = 'gibtesnicht'

      expect { run_task }.to raise_error(SystemExit).and(output(/unbekannte Organisation/).to_stderr)
      expect(Chat.unscoped.count).to eq(1)
    end

    # A list in which ONE entry is wrong is still an abort: otherwise the run
    # works on a subset nobody ordered.
    it 'bricht ab, wenn nur ein Eintrag der Liste unbekannt ist' do
      project_thread
      ENV['ORGS'] = "#{organisation.name},gibtesnicht"

      expect { run_task }.to raise_error(SystemExit)
      expect(Chat.unscoped.count).to eq(1)
    end

    # The name is protected by a model validation, but by NO unique index. Relying on
    # an application callback as the only guarantee before an irreversible mass delete
    # is exactly the assumption that gets expensive here. `update_column` creates the
    # state the database allows.
    it 'bricht bei einem mehrdeutigen Namen ab, statt beide zu treffen' do
      project_thread
      other_organisation.update_column(:name, organisation.name)
      ENV['ORGS'] = organisation.name

      expect { run_task }.to raise_error(SystemExit).and(output(/mehrdeutige Organisation/).to_stderr)
      expect(Chat.unscoped.count).to eq(1)
    end
  end

  # The switch left together with the column chats.ticket_id (S4-T1). A switch that is set
  # is a decision the run no longer knows; swallowing it silently would be the wrong
  # direction, the same as with a DRY_RUN it does not understand.
  it 'bricht ab, wenn der seit S4-T1 wirkungslose Schalter INCLUDE_TICKET_THREADS gesetzt ist' do
    project_thread
    ENV['INCLUDE_TICKET_THREADS'] = '1'

    expect { run_task }.to raise_error(SystemExit).and(output(/INCLUDE_TICKET_THREADS ist seit S4-T1/).to_stderr)
    expect(Chat.unscoped.count).to eq(1)
  end

  describe 'die Ausgabe' do
    it 'nennt im Trockenlauf die betroffenen Organisationen und loescht nichts' do
      project_thread
      ENV['DRY_RUN'] = '1'

      expect { run_task }.to output(/#{Regexp.escape(organisation.name[0, 30])}/).to_stdout
      expect(Chat.unscoped.count).to eq(1)
    end

    # A silent zero run reads like a success; usually it is an ORGS that is too narrow.
    it 'sagt es, wenn nichts auf den Schnitt passte' do
      expect { run_task }.to output(/Nichts geloescht/).to_stdout
    end
  end
end

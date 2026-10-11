# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake notifications:purge_project_leftovers`, a data backfill
#       (Lalabase::DataBackfills::TASKS).
# Why:  Until 2026-10-08 ProjectDeletionJob kept a deleted project's notifications
#       and emptied their project_id. A row without a project passes the inbox rule
#       as a system message (Notification.readable), so what an area right had
#       hidden (a moved ticket's title, a new member's address, a repository's name)
#       came back through the token inbox. The job now deletes the rows; this task
#       deletes the ones it left before: no project, a subject that always lives in
#       a project, and that subject gone. A row with a mail log stays, as in the job:
#       a later bounce finds its person through it. Idempotent.
RSpec.describe 'notifications:purge_project_leftovers', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation) }
  end

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?('notifications:purge_project_leftovers') }

  before { Rake::Task['notifications:purge_project_leftovers'].reenable }

  def row(notifiable, project: self.project, organisation: self.organisation, channel: 'in_app')
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, organisation: organisation, project: project, notifiable: notifiable, channel: channel)
    end
  end

  # What a deleted project left: the row without a project, its subject (of `type`) gone.
  def leftover(type, organisation: self.organisation, channel: 'in_app')
    subject = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    row(subject, project: subject, organisation: organisation, channel: channel).tap do |notification|
      notification.update_columns(project_id: nil, notifiable_type: type, notifiable_id: SecureRandom.uuid)
    end
  end

  def run_task = Rake::Task['notifications:purge_project_leftovers'].invoke

  def existing(rows) = ActsAsTenant.without_tenant { Notification.where(id: rows.map(&:id)).pluck(:id) }

  # Every subject that always lives in a project, one of them in a second organisation:
  # a task that knew fewer types, or one organisation only, leaves one behind.
  let(:project_bound) do
    %w[Ticket Note Document Project ProjectRepository Meeting MeetingAnalysis Post TimeSession]
  end

  it 'deletes the leftovers of every project-bound subject, in every organisation, and only those' do
    leftovers = project_bound.map { |type| leftover(type) } + [leftover('Ticket', organisation: other_organisation)]
    mailed = leftover('Project', channel: 'email')
    mail_log = ActsAsTenant.with_tenant(organisation) { create(:email_log, organisation: organisation, notification: mailed) }
    kept = [
      mailed,                                              # went out: its mail log carries a later bounce
      row(organisation, project: nil),                     # a system message
      row(ticket, project: nil),                           # no project, but its ticket lives: not a leftover
      row(ticket).tap { |n| n.update_columns(notifiable_id: SecureRandom.uuid) } # a deleted ticket in a live project
    ]

    expect { run_task }.to output(/ #{leftovers.size} notifications/).to_stdout

    expect(existing(leftovers)).to be_empty
    expect(existing(kept)).to match_array(kept.map(&:id))
    expect(ActsAsTenant.without_tenant { EmailLog.where(id: mail_log.id) }).to exist
  end

  it 'touches nothing the second time' do
    leftover('Project')
    run_task
    Rake::Task['notifications:purge_project_leftovers'].reenable

    expect { run_task }.to output(/ 0 notifications/).to_stdout
  end

  it 'is listed as a data backfill' do
    expect(Lalabase::DataBackfills::TASKS).to include('notifications:purge_project_leftovers')
  end
end

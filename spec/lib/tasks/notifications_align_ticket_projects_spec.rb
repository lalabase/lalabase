# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake notifications:align_ticket_projects`, a data backfill
#       (Lalabase::DataBackfills::TASKS).
# Why:  The inbox rule measures a notification by its project_id and the area of
#       its subject (Notification.readable). Until 2026-10-07 moving a ticket left
#       its notifications in the old project: a person who could read tickets
#       there but not in the new project kept the row, with the ticket's current
#       title. Tickets::Mover now moves them along; this task aligns the rows of
#       tickets moved before. Idempotent: an aligned row is never touched again.
RSpec.describe 'notifications:align_ticket_projects', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:old_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:new_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: new_project, organisation: organisation) }
  end

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?('notifications:align_ticket_projects') }

  before { Rake::Task['notifications:align_ticket_projects'].reenable }

  def row(project)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, organisation: organisation, project: project, notifiable: ticket)
    end
  end

  it 'moves the rows of a moved ticket to its project, and only those' do
    stale = row(old_project)
    current = row(new_project)
    news = ActsAsTenant.with_tenant(organisation) do
      create(:notification, organisation: organisation, project: old_project, notifiable: old_project)
    end

    expect { Rake::Task['notifications:align_ticket_projects'].invoke }.to output(/1 notifications/).to_stdout

    projects = ActsAsTenant.without_tenant { Notification.where(id: [stale, current, news].map(&:id)).pluck(:id, :project_id).to_h }
    expect(projects.values_at(stale.id, current.id, news.id)).to eq([new_project.id, new_project.id, old_project.id])
  end

  it 'touches nothing the second time' do
    row(old_project)
    Rake::Task['notifications:align_ticket_projects'].invoke
    Rake::Task['notifications:align_ticket_projects'].reenable

    expect { Rake::Task['notifications:align_ticket_projects'].invoke }.to output(/ 0 notifications/).to_stdout
  end

  it 'is listed as a data backfill' do
    expect(Lalabase::DataBackfills::TASKS).to include('notifications:align_ticket_projects')
  end
end

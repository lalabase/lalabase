# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake permissions:prune_unknown_actions`, a data backfill
#       (Lalabase::DataBackfills::TASKS).
# Why:  A role's stored permission whose action left Permission::CATEGORIES is
#       an invalid record that nothing reads as a right, while the guest
#       ceiling of its role still counts an allowed 'projects' row. Removing the
#       Prozesse rights in October 2026 left two such rows on production
#       (read_/write_access_processes_all_projects). The task removes every row
#       whose category and action the code does not know, so the next removed
#       right needs no task of its own.
RSpec.describe 'permissions:prune_unknown_actions' do
  let(:organisation) { create(:organisation) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?('permissions:prune_unknown_actions') }

  before { Rake::Task['permissions:prune_unknown_actions'].reenable }

  def stored(category, action)
    Permission.insert_all!([{ role_id: role.id, category: category, action: action, allowed: true,
                              created_at: Time.current, updated_at: Time.current }])
  end

  def actions = Permission.where(role_id: role.id).order(:action).pluck(:action)

  it 'removes rows the code no longer knows and keeps the known ones' do
    stored('projects', 'read_access_tickets_all_projects')
    stored('projects', 'read_access_processes_all_projects')
    stored('projects', 'write_access_processes_all_projects')
    stored('gone_category', 'anything')
    stored('tickets', 'read_access_tickets_all_projects') # a known action under the wrong category

    expect { Rake::Task['permissions:prune_unknown_actions'].invoke }
      .to output(/4 stored permissions/).to_stdout

    expect(actions).to eq(['read_access_tickets_all_projects'])
    expect(ActsAsTenant.with_tenant(organisation) { Permission.where(role_id: role.id).all?(&:valid?) }).to be(true)
  end

  it 'touches nothing the second time' do
    stored('projects', 'read_access_processes_all_projects')
    Rake::Task['permissions:prune_unknown_actions'].invoke
    Rake::Task['permissions:prune_unknown_actions'].reenable

    expect { Rake::Task['permissions:prune_unknown_actions'].invoke }.to output(/0 stored permissions/).to_stdout
  end

  it 'is a data backfill, so every installation runs it' do
    expect(Lalabase::DataBackfills::TASKS).to include('permissions:prune_unknown_actions')
  end
end

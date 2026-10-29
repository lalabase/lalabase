# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake activities:drop_member_emails`, a data backfill.
# Why:  project.member_added stored the member's login address in its parameters
#       until 2026-10-29. Every reader of the project's members area sees and
#       searches those rows, and a member now chooses which email the others see
#       (User::EmailDisplay). The task removes the key from the old rows.
RSpec.describe 'activities:drop_member_emails', :ci_guard do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('activities:drop_member_emails')
  end

  before { Rake::Task['activities:drop_member_emails'].reenable }

  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:member) { create(:user, email: 'member-login@example.com') }

  def activity_with(parameters)
    ActsAsTenant.with_tenant(organisation) do
      create(:activity, trackable: project, organisation: organisation, secondary: member,
                        key: 'project.member_added', action: 'member_added', parameters: parameters)
    end
  end

  it 'removes the stored login address and keeps every other parameter' do
    old_row = activity_with('user_name' => 'Mia Mitglied', 'user_email' => 'member-login@example.com', 'tickets_access' => 'read_only')

    expect { Rake::Task['activities:drop_member_emails'].invoke }.to output(/1 activities/).to_stdout

    expect(old_row.reload.parameters).to eq('user_name' => 'Mia Mitglied', 'tickets_access' => 'read_only')
  end

  it 'leaves rows without the key alone and touches nothing the second time' do
    new_row = activity_with('user_name' => 'Mia Mitglied')
    activity_with('user_email' => 'member-login@example.com')

    expect { Rake::Task['activities:drop_member_emails'].invoke }.to output(/1 activities/).to_stdout
    Rake::Task['activities:drop_member_emails'].reenable
    expect { Rake::Task['activities:drop_member_emails'].invoke }.to output(/0 activities/).to_stdout

    expect(new_row.reload.parameters).to eq('user_name' => 'Mia Mitglied')
  end

  it 'runs on every deploy' do
    expect(Lalabase::DataBackfills::TASKS).to include('activities:drop_member_emails')
  end
end

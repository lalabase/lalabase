# frozen_string_literal: true

require 'rails_helper'

# What db/seeds.rb leaves behind, per environment (S0, doc/oss_core_split_plan.md §8).
#
# Pinned: a server gets reference data and nothing else, above all no demo accounts
# with the password printed in this repository; development gets a demo a
# contributor can sign in to; and every run can be repeated without error.
RSpec.describe 'db/seeds.rb' do
  def seed(env)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(env))
    # The seed files define constants; a second load in one process would warn.
    %i[GLOBAL_PROMPT_PERSONAS DemoSeed].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    silence_stream($stdout) { load Rails.root.join('db/seeds.rb') }
  end

  def silence_stream(stream)
    original = stream.dup
    stream.reopen(File::NULL)
    yield
  ensure
    stream.reopen(original)
  end

  after { Object.send(:remove_const, :DemoSeed) if defined?(DemoSeed) }

  context 'in production' do
    it 'seeds the persona pool and no account at all' do
      seed('production')
      seed('production')

      expect(PromptPersona.where(organisation_id: nil, key: PromptPersona::DEFAULT_KEY)).to exist
      expect([User.where.not(email: User.system.email).count, Beuser.count, Organisation.count]).to eq([0, 0, 0])
    end
  end

  context 'in development' do
    it 'builds a demo two people can sign in to, and a second run changes nothing' do
      seed('development')
      counts = -> { ActsAsTenant.without_tenant { [User.count, Organisation.count, Project.count, Ticket.count, Beuser.count] } }
      after_first_run = counts.call
      seed('development')

      expect(counts.call).to eq(after_first_run)

      admin = User.find_by!(email: 'anna@example.com')
      member = User.find_by!(email: 'ben@example.com')
      expect([admin, member]).to all(be_confirmed)
      expect(admin.valid_password?('lalabase-demo')).to be(true)

      organisation = admin.organisations.find_by!(name: 'Beispiel GmbH')
      expect(member.organisations).to contain_exactly(organisation)
      manager = User.find_by!(email: 'clara@example.com')
      viewer = User.find_by!(email: 'david@example.com')

      ActsAsTenant.with_tenant(organisation) do
        # The signup's own onboarding tutorial plus the demo project.
        expect(organisation.projects.pluck(:system_kind)).to contain_exactly('onboarding', nil)
        project = organisation.projects.find_by!(name: 'Website-Relaunch')
        expect(project.tickets.count).to eq(5)
        expect(project.users_with_access(:read, :tickets)).to include(member)
        expect(project.tickets.joins(:assignees).where(users: { id: member.id }).count).to eq(2)

        # One person per role; the roles are what the demo is there to show.
        roles = organisation.memberships.includes(:role, :user).to_h { |membership| [membership.user.email, membership.role] }
        expect(roles.except('anna@example.com').transform_values(&:title)).to eq(
          'ben@example.com' => organisation.find_or_create_default_role.title,
          'clara@example.com' => 'Projektmanager', 'david@example.com' => 'Betrachter'
        )
        expect(roles['anna@example.com']).to be_account_admin

        # Both example roles read every project without a project permission of their
        # own; only the manager may create projects, and the viewer never writes.
        expect(project.users_with_access(:read, :meetings)).to include(manager, viewer)
        expect(project.users_with_access(:write, :tickets)).not_to include(viewer)
        rights = ->(user) { roles[user.email].permissions.where(allowed: true).pluck(:action) }
        expect(rights.call(manager)).to include('create_new_projects', 'read_access_meetings_all_projects')
        expect(rights.call(viewer)).to include('read_access_meetings_all_projects')
        expect(rights.call(viewer)).not_to include('create_new_projects', 'change_project_properties')
      end

      expect(Beuser.find_by!(email: 'admin@example.com')).to be_active
    end
  end

  it 'refuses to build the demo in production even when loaded directly' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))

    expect { load Rails.root.join('db/seeds/demo.rb') }.to raise_error(/development only/)
    expect(User.where(email: 'anna@example.com')).not_to exist
  end
end

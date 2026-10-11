# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_tasks
#
#  id              :uuid             not null, primary key
#  completed_at    :datetime
#  position        :integer          default(0), not null
#  priority        :integer
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_personal_tasks_on_org_user_completed  (organisation_id,user_id,completed_at)
#  index_personal_tasks_on_user_id             (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
require 'rails_helper'

# Mutation-test mindset (tests-schaerfen): each example targets a real decision
# point — the title rails, the nullable-enum default, the open/done split, the
# position+recency ordering, the toggle transition, and the two isolation walls
# (tenant AND per-user) that make the to-dos private.
RSpec.describe PersonalTask, type: :model do
  let(:organisation)       { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user)               { create(:user) }

  # acts_as_tenant: every create/query needs a tenant. Set it in a `before`
  # (NOT `around`) — DatabaseCleaner resets the tenant to nil in its own
  # before(:each), which is registered first, so this runs after it. Cross-org
  # examples open a nested with_tenant explicitly.
  before { ActsAsTenant.current_tenant = organisation }

  describe 'validations' do
    it 'requires a present (non-blank) title' do
      expect(build(:personal_task, organisation: organisation, user: user, title: nil)).not_to be_valid
      expect(build(:personal_task, organisation: organisation, user: user, title: '   ')).not_to be_valid
    end

    it 'accepts a title at the cap and rejects one past it (n / n+1 boundary)' do
      cap = PersonalTask::TITLE_MAX_LENGTH
      expect(build(:personal_task, organisation: organisation, user: user, title: 'a' * cap)).to be_valid
      expect(build(:personal_task, organisation: organisation, user: user, title: 'a' * (cap + 1))).not_to be_valid
    end

    it 'requires a user (belongs_to presence)' do
      expect(build(:personal_task, organisation: organisation, user: nil)).not_to be_valid
    end
  end

  describe 'priority enum (nullable)' do
    it 'defaults to nil = no priority, and accepts the three levels' do
      expect(create(:personal_task, organisation: organisation, user: user).priority).to be_nil
      expect(create(:personal_task, organisation: organisation, user: user, priority: :high).priority).to eq('high')
    end

    it 'cannot persist an unknown priority (setter raises)' do
      expect { build(:personal_task, organisation: organisation, user: user, priority: :urgent) }
        .to raise_error(ArgumentError)
    end
  end

  describe 'scopes' do
    it '.open and .done partition by completed_at' do
      open_task = create(:personal_task, organisation: organisation, user: user)
      done_task = create(:personal_task, :done, organisation: organisation, user: user)

      expect(PersonalTask.open).to contain_exactly(open_task)
      expect(PersonalTask.done).to contain_exactly(done_task)
    end

    it '.ordered sorts by position asc, then newest created_at first' do
      first_made  = create(:personal_task, organisation: organisation, user: user, position: 0, created_at: 2.minutes.ago)
      second_made = create(:personal_task, organisation: organisation, user: user, position: 0, created_at: 1.minute.ago)
      pinned      = create(:personal_task, organisation: organisation, user: user, position: -1, created_at: Time.current)

      # position -1 wins outright; within equal position, newest-first.
      expect(PersonalTask.ordered.to_a).to eq([pinned, second_made, first_made])
    end
  end

  describe '#toggle_completed!' do
    it 'marks an open task done with a timestamp' do
      task = create(:personal_task, organisation: organisation, user: user)

      expect { task.toggle_completed! }.to change { task.reload.completed? }.from(false).to(true)
      expect(task.completed_at).to be_present
    end

    it 'reopens a done task (clears completed_at)' do
      task = create(:personal_task, :done, organisation: organisation, user: user)

      expect { task.toggle_completed! }.to change { task.reload.completed? }.from(true).to(false)
      expect(task.completed_at).to be_nil
    end
  end

  describe 'tenant isolation (acts_as_tenant)' do
    it 'never surfaces tasks from another organisation' do
      mine  = create(:personal_task, organisation: organisation, user: user)
      other = ActsAsTenant.with_tenant(other_organisation) do
        create(:personal_task, organisation: other_organisation, user: user)
      end

      # Tenant is `organisation` here, so the default scope excludes the other org.
      expect(PersonalTask.all).to contain_exactly(mine)
      expect(PersonalTask.all).not_to include(other)
    end
  end

  describe 'per-user isolation within one organisation' do
    it 'where(user:) returns only that user\'s tasks (an admin cannot widen via scope)' do
      other_user = create(:user)
      mine       = create(:personal_task, organisation: organisation, user: user)
      theirs     = create(:personal_task, organisation: organisation, user: other_user)

      expect(PersonalTask.where(user: user)).to contain_exactly(mine)
      expect(PersonalTask.where(user: user)).not_to include(theirs)
    end
  end
end

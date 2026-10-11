# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake posts:redact_private_excerpts`, the one-off cleanup after the
#   private-comment fix.
# Why: before 27.09.2026 every comment left its text in the activity feed and in the
#   notifications, private ones too. The fix stops new excerpts; without this run the
#   old ones stay readable in the feed and the activities API. It must touch private
#   comments only and leave a public comment's excerpt alone.
RSpec.describe 'posts:redact_private_excerpts', :ci_guard do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('posts:redact_private_excerpts')
  end

  before { Rake::Task['posts:redact_private_excerpts'].reenable }

  let(:organisation) { create(:organisation) }
  let(:ticket) { create(:ticket, project: create(:project, organisation: organisation), organisation: organisation) }
  let(:author) { create(:user) }
  let(:recipient) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # The shape the old code wrote: an excerpt on the activity, copied into the notification
  def old_comment(text, is_private:)
    Prosopite.pause do
      post = create(:post, ticket: ticket, user: author, content: text, is_private: is_private)
      activity = create(:activity, trackable: ticket, secondary: post, action: 'post_added', key: 'ticket.post_added',
                                   organisation: organisation, parameters: { 'post_excerpt' => text })
      create(:notification, recipient: recipient, organisation: organisation, notifiable: ticket,
                            payload: { 'activity_id' => activity.id, 'parameters' => { 'post_excerpt' => text } })
      [post, activity]
    end
  end

  def run_task
    Prosopite.pause { expect { Rake::Task['posts:redact_private_excerpts'].invoke }.to output(/Done/).to_stdout }
  end

  it 'removes the excerpt of a private comment from its activity and notification' do
    _post, activity = old_comment('Private salary figure', is_private: true)

    run_task

    expect(activity.reload.parameters).not_to have_key('post_excerpt')
    expect(Notification.where(recipient: recipient).map { |n| n.payload.to_json }.join).not_to include('salary')
  end

  # The task finds its posts through the activity's excerpt: an activity cleaned
  # without its notifications would never be selected again.
  it 'leaves the activity untouched when cleaning the notifications fails' do
    _post, activity = old_comment('Private salary figure', is_private: true)
    allow(Notification).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

    expect { Prosopite.pause { Rake::Task['posts:redact_private_excerpts'].invoke } }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect(activity.reload.parameters['post_excerpt']).to eq('Private salary figure')
  end

  it "keeps a public comment's excerpt" do
    _post, activity = old_comment('Public remark', is_private: false)

    run_task

    expect(activity.reload.parameters['post_excerpt']).to eq('Public remark')
  end
end

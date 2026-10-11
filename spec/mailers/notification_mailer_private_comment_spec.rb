# frozen_string_literal: true

require 'rails_helper'

# What: the comment mail shows a comment, and the "previous comment" above it, only
#   when its recipient may read them (Post.readable_by).
# Why: until 27.09.2026 the mail quoted the last comment before the new one, whoever
#   it was private to. The fanout now picks readers only, but the mail is rendered
#   later, in a job: a comment can turn private in between, so the mail asks again.
RSpec.describe NotificationMailer, '#ticket_comment and private comments', :ci_guard, type: :mailer do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:author) { create(:user) }
  let(:recipient) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      [author, recipient].each do |user|
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
      end
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def comment(text, is_private: false, at: Time.current)
    Prosopite.pause { create(:post, ticket: ticket, user: author, content: text, is_private: is_private, created_at: at) }
  end

  def mail_about(post)
    Prosopite.pause do
      activity = create(:activity, trackable: ticket, secondary: post, action: 'post_added', key: 'ticket.post_added',
                                   organisation: organisation, actor: author, parameters: {})
      notification = create(:notification, recipient: recipient, organisation: organisation, notifiable: ticket,
                                           event_type: 'ticket_commented', channel: 'email',
                                           payload: { 'activity_id' => activity.id, 'parameters' => {} })
      mail = described_class.ticket_comment(notification)
      [mail.html_part, mail.text_part].map { |part| part.body.decoded }.join
    end
  end

  it 'quotes a readable previous comment' do
    comment('Earlier public remark', at: 1.hour.ago)

    expect(mail_about(comment('New remark'))).to include('Earlier public remark')
  end

  it "does not quote someone else's private comment as the previous one" do
    comment('Earlier public remark', at: 2.hours.ago)
    comment('Private salary figure', is_private: true, at: 1.hour.ago)

    body = mail_about(comment('New remark'))

    expect(body).not_to include('Private salary figure')
    expect(body).to include('Earlier public remark')
  end

  it 'leaves out the comment itself once the recipient may no longer read it' do
    body = mail_about(comment('Turned private in between', is_private: true))

    expect(body).not_to include('Turned private in between')
  end
end

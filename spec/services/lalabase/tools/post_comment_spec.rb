# frozen_string_literal: true

require 'rails_helper'

# Direct calls bypass the MCP schema. Keep HTML's existing storage and answer,
# and reject malformed plain input before ActionText or PostgreSQL receives it.
RSpec.describe Lalabase::Tools::PostComment do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: user) }
  let(:context) do
    Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project,
                                 authorization: Lalabase::Tools::AuthorizationRecorder.new)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: :read_write)
    ticket
  end
  after { ActsAsTenant.current_tenant = nil }

  def execute(arguments)
    described_class.execute(args: { ticket_id: ticket.id, body: 'Hello' }.merge(arguments), context: context)
  end

  it 'declares only html and plain as optional string formats, with html as the default' do
    schema = described_class.input_schema
    expect(schema[:properties][:format]).to include(type: 'string', enum: %w[html plain])
    expect(schema[:properties][:format][:description]).to match(/html.*default/i)
    expect(schema[:required]).to eq(%w[ticket_id body])
  end

  [{}, { format: 'html' }].each do |options|
    it "keeps the legacy HTML storage and full answer for #{options.inspect}" do
      body = "<p><b>bold</b> &lt;tag&gt;\nline</p><p>next</p>"
      result = execute(options.merge(body: body))
      saved = Post.find(JSON.parse(result.content).fetch('id'))
      expect(result).to be_success
      expect(saved.content.body.to_html).to eq(body)
      expect(saved.plain_text_version).to eq("bold <tag>\nline\n\nnext")
      expect(result.content).to eq(JSON.pretty_generate(
                                     id: saved.id, ticket_id: ticket.id, author: { id: user.id, name: user.display_name },
                                     body_text: "bold <tag>\nline\n\nnext", is_private: false, created_at: saved.created_at.iso8601
                                   ))
    end
  end

  invalid = {
    'an unknown format' => [{ format: 'markdown' }, 'format must be html or plain'],
    'a numeric format' => [{ format: 1 }, 'format must be a string'],
    'a null format' => [{ format: nil }, 'format must be a string'],
    'a symbol format' => [{ format: :plain }, 'format must be a string'],
    'invalid UTF-8' => [{ format: 'plain', body: 255.chr.force_encoding(Encoding::UTF_8) }, 'body must be valid UTF-8'],
    'a NUL byte' => [{ format: 'plain', body: "a#{0.chr}b" }, 'body must not contain NUL bytes'],
    'invalid UTF-8 in an html body' => [{ body: 255.chr.force_encoding(Encoding::UTF_8) }, 'body must be valid UTF-8'],
    'a plain body of only a no-break space' => [{ format: 'plain', body: 0xA0.chr(Encoding::UTF_8) }, 'body is required'],
    'a plain body of only an em space' => [{ format: 'plain', body: 0x2003.chr(Encoding::UTF_8) }, 'body is required']
  }

  invalid.each do |label, (arguments, message)|
    it "rejects #{label} as invalid_input without writing" do
      result = nil
      expect { result = execute(arguments) }.not_to change(Post, :count)
      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to eq(message)
    end
  end

  # The web comment is Actors::SavePost. A bare Post#save beside it produced no
  # activity, no notification and no embedding until 2026-10-10.
  describe 'side effects shared with the web path (Actors::SavePost)' do
    let(:subscriber) { create(:user) }

    before do
      create(:membership, user: subscriber, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: subscriber, project: project, tickets_access: :read_write)
      NotificationSubscription.create!(user: subscriber, subscribable: ticket, mode: :follow)
    end

    def saved_post(result)
      Post.find(JSON.parse(result.content).fetch('id'))
    end

    it 'records a post_added activity naming the comment and its author' do
      saved = saved_post(execute(format: 'plain', body: 'Hallo'))
      activity = Activity.find_by(action: 'post_added', secondary: saved)
      expect(activity).to be_present
      expect(activity.trackable).to eq(ticket)
      expect(activity.actor).to eq(user)
      expect(activity.parameters['post_excerpt']).to eq('Hallo')
    end

    it 'reaches a subscriber as ticket_commented through the outbox' do
      saved = saved_post(execute(body: 'Hallo'))
      outbox_event = OutboxEvent.find_by!(activity: Activity.find_by!(action: 'post_added', secondary: saved))
      Prosopite.pause
      Notifications::FanoutService.new(outbox_event).call
      Prosopite.resume
      expect(Notification.where(recipient: subscriber, notifiable: ticket, event_type: 'ticket_commented')).to exist
    end

    it "marks the author's own unread notifications about the ticket as read" do
      own = create(:notification, :ticket_commented, organisation: organisation, recipient: user, actor: subscriber,
                                                     notifiable: ticket, project: project)
      execute(body: 'Hallo')
      expect(own.reload.state).to eq('read')
    end
  end
end

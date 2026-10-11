# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::MarkNotificationRead, the token-scoped inbox write
#       (inbox workflow S3).
# Type: Service spec.
# Why:  A token-scoped write has no project gate, so the row lookup IS the
#       reach check: another user's row, a row outside the token's organisations
#       and a missing id all read the same and change nothing. The policy runs
#       under the row's own tenant (it compares organisations), and the D7
#       decision is marked.
RSpec.describe Lalabase::Tools::MarkNotificationRead do
  let(:user) { create(:user) }
  let(:stranger) { create(:user) }
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:token) { create(:personal_access_token, user: user, organisations: [organisation]) }

  before { make_token_owner_a_member(user, organisation) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) { Lalabase::Tools::Context.new(actor: user, reach: token.reach, authorization: recorder) }

  def row(org, **attrs)
    ActsAsTenant.with_tenant(org) do
      create(:notification, { recipient: user, organisation: org, state: 'queued' }.merge(attrs))
    end
  end

  def run(args)
    described_class.execute(args: args, context: context)
  end

  describe 'contract metadata' do
    it 'is a token-scoped, mutating, record-mode tool that requires the actor' do
      expect(described_class.scope_mode).to eq(:token)
      expect(described_class.mutating?).to be true
      expect(described_class.requires_actor?).to be true
      expect(described_class.authorization_mode).to eq(:record)
    end
  end

  it 'marks an unread row of the token owner as read and marks the decision (D7)' do
    mine = row(organisation)
    result = run(notification_id: mine.id)
    expect(result.success?).to be true
    payload = JSON.parse(result.content)
    expect(payload).to include('id' => mine.id, 'state' => 'read')
    expect(payload['read_at']).to be_present
    expect(mine.reload.state).to eq('read')
    expect(recorder.authorized?).to be true
  end

  it 'leaves a read row read, with its original read_at' do
    read_at = 1.hour.ago.change(usec: 0)
    mine = row(organisation, state: 'read', read_at: read_at)
    payload = JSON.parse(run(notification_id: mine.id).content)
    expect(payload['state']).to eq('read')
    expect(payload['read_at']).to eq(read_at.iso8601)
  end

  # One lookup per example (Prosopite reads repeated identical lookups as N+1).
  describe 'a row it must not touch' do
    let!(:theirs) { row(organisation, recipient: stranger) }
    let!(:outside) { row(other_organisation) }

    def expect_not_found(id)
      result = run(notification_id: id)
      expect(result.empty?).to be true
      expect(result.content).to match(/No notification found/)
      expect(theirs.reload.state).to eq('queued')
      expect(outside.reload.state).to eq('queued')
      expect(recorder.authorized?).to be false
    end

    it "reads another user's row as not found" do
      expect_not_found(theirs.id)
    end

    it 'reads a row outside the token reach as not found' do
      expect_not_found(outside.id)
    end

    it 'reads a missing id as not found' do
      expect_not_found(SecureRandom.uuid)
    end
  end

  it 'refuses an archived row instead of answering "archived" to a request it did not fulfil' do
    archived = row(organisation, state: 'archived', read_at: nil)
    result = run(notification_id: archived.id)
    expect(result.error).to match(/archived/)
    expect(archived.reload.state).to eq('archived')
  end

  it 'refuses the project_id filter it does not read (not advertised for this tool)' do
    mine = row(organisation)
    result = run(notification_id: mine.id, project_id: SecureRandom.uuid)
    expect(result.error).to match(/project_id does not apply/)
    expect(mine.reload.state).to eq('queued')
  end

  it 'refuses a context without a token reach' do
    project_context = Lalabase::Tools::Context.new(actor: user, organisation: organisation)
    expect(described_class.execute(args: { notification_id: SecureRandom.uuid }, context: project_context).error)
      .to match(/token context/)
  end

  it 'rejects a missing or malformed notification_id without hitting the database' do
    expect(run({}).error).to eq('notification_id is required')
    expect(run(notification_id: '42').error).to eq('invalid notification_id format')
  end
end

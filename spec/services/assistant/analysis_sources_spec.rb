# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Assistant::AnalysisSources do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation), active: true)
    create(:project_permission, user: user, project: project, meetings_access: 'read_write', tickets_access: 'read_only', documentation_access: 'read_only')
  end
  after { ActsAsTenant.current_tenant = nil }

  def readable(*citations)
    described_class.readable?(citations: citations.map(&:stringify_keys), organisation: organisation, user: user)
  end

  it 'rejects deleted, unknown and cross-organisation sources' do
    expect(readable(Lalabase::Citations.meeting(meeting))).to be true
    citation = Lalabase::Citations.meeting(meeting)
    meeting.destroy!
    expect(readable(citation)).to be false
    expect(readable(type: 'unexpected', id: SecureRandom.uuid)).to be false
    foreign = create(:organisation)
    other = ActsAsTenant.with_tenant(foreign) { create(:meeting) }
    expect(readable(Lalabase::Citations.meeting(other))).to be false
  end

  it 'rechecks private ticket comments embedded in a ticket tool response' do
    ticket = create(:ticket, project: project, organisation: organisation)
    comment = create(:post, ticket: ticket, user: user, is_private: false)
    citation = Lalabase::Citations.ticket(ticket).merge(post_ids: [comment.id])
    expect(readable(citation)).to be true
    comment.update!(user: create(:user), is_private: true)
    expect(readable(citation)).to be false
  end

  it 'rejects incomplete time-report provenance' do
    expect(readable(Lalabase::Citations.time_report(project).merge(scope: 'all'))).to be false
  end

  %w[unverified_history unverified_tool_sources].each do |type|
    it "rejects the #{type} marker even among valid sources" do
      expect(readable(Lalabase::Citations.meeting(meeting), type: type)).to be false
    end
  end

  it 'checks both meeting identity and project identity before publication' do
    citation = Lalabase::Citations.meeting(meeting).stringify_keys
    [citation.merge('id' => SecureRandom.uuid), citation.merge('project_id' => SecureRandom.uuid),
     { 'type' => 'project', 'id' => SecureRandom.uuid }, { 'type' => 'unverified_history' },
     { 'type' => 'unverified_tool_sources' }].each do |invalid|
      expect(described_class.publishable?(context: { 'provenance' => [citation, invalid] }, meeting: meeting)).to be false
    end
    expect(described_class.publishable?(context: { 'provenance' => [citation, { 'type' => 'project', 'id' => project.id }] }, meeting: meeting)).to be true
  end

  it 'allows legacy publication but keeps non-meeting and differently scoped provenance private' do
    expect(described_class.publishable?(context: nil, meeting: meeting)).to be true
    context = { 'provenance' => [Lalabase::Citations.meeting(meeting).stringify_keys] }
    expect(described_class.publishable?(context: context, meeting: meeting)).to be true
    context['provenance'] << { 'type' => 'note', 'id' => SecureRandom.uuid }
    expect(described_class.publishable?(context: context, meeting: meeting)).to be false
  end
end

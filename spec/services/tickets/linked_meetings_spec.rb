# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Tickets::LinkedMeetings do
  let(:organisation) { create(:organisation) }
  let(:creator) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, creator: creator) }
  end
  let(:reader) do
    create(:user).tap do |user|
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        create(:project_permission, user: user, project: project, meetings_access: 'read_only')
      end
    end
  end

  def meeting_linked_at(time, title)
    ActsAsTenant.with_tenant(organisation) do
      meeting = create(:meeting, project: project, organisation: organisation, creator: creator, title: title)
      meeting.outgoing_references.create!(organisation: organisation, target: ticket,
                                          target_title_snapshot: ticket.display_title, created_at: time)
      meeting
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'resolves no permissions for a ticket without meeting links' do
    expect(MeetingPolicy::Scope).not_to receive(:new)

    expect(described_class.call(ticket: ticket, user: reader)).to be_empty
  end

  it 'names no meeting for a ticket without links, while meetings link to other tickets' do
    other = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: creator)
    end
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: creator)
        .outgoing_references.create!(organisation: organisation, target: other, target_title_snapshot: other.display_title)
    end

    expect(described_class.call(ticket: ticket, user: reader)).to be_empty
  end

  it 'lists the linking meetings oldest link first, whatever their own dates' do
    later = meeting_linked_at(1.hour.ago, 'Linked second')
    earlier = meeting_linked_at(2.hours.ago, 'Linked first')

    expect(described_class.call(ticket: ticket, user: reader).map(&:title)).to eq([earlier.title, later.title])
  end

  it 'ignores a reference from something other than a meeting' do
    note = create(:note, project: project, organisation: organisation, creator: creator)
    Reference.create!(organisation: organisation, source: note, target: ticket,
                      target_title_snapshot: ticket.display_title)

    expect(described_class.call(ticket: ticket, user: reader)).to be_empty
  end
end

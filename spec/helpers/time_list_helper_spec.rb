# frozen_string_literal: true

require 'rails_helper'

# The link from a subject's booked time into the time list. It is rendered once per row of the
# ticket table (the time column), so building it must not look anything up: an address needs
# ids, not records (review round 4 of #949 found a lookup of the organisation per row).
RSpec.describe TimeListHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  after { ActsAsTenant.current_tenant = nil }

  def queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  describe '#subject_time_list_path' do
    it "links a ticket's time by its id, in its project, with the list defaults neutralised" do
      ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }

      expect(helper.subject_time_list_path(ticket)).to eq(
        helper.time_list_path(organisation, project: project, ticket_id: ticket.id,
                                            **TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)
      )
    end

    it "links a meeting's time by its id" do
      meeting = ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation) }

      expect(helper.subject_time_list_path(meeting)).to include("meeting_id=#{meeting.id}", "project_id_filter=#{project.id}")
    end

    it 'looks up neither the organisation nor the project' do
      ticket = ActsAsTenant.with_tenant(organisation) { Ticket.find(create(:ticket, project: project).id) }

      expect(queries { helper.subject_time_list_path(ticket) }).to eq(0)
    end
  end
end

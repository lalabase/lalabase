# frozen_string_literal: true

require 'rails_helper'

# What: Activity.feed (doc/ticket_bulk_edit_plan.md, D12), and the readers that use it.
# Type: model spec plus a source guard.
# Why: a bulk run is one line on the project; the tickets' own activities of the
#   run stay out of every feed but in the ticket's timeline. A reader that
#   shows a feed without the scope would show two hundred lines again.
RSpec.describe 'Activity.feed', :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { bulk_project_setup }
  after { ActsAsTenant.current_tenant = nil }

  it 'hides the per-ticket activities of a run and keeps the run line and every other activity' do
    tickets = [bulk_ticket, bulk_ticket]
    single = bulk_ticket
    Actors::ApplyTicketChanges.call(project: project, ticket_ids: tickets.map(&:id), current_user: writer,
                                    changes: [{ 'field' => 'status', 'value' => 'wip' }])
    Actors::ApplyTicketChanges.call(project: project, ticket_ids: [single.id], current_user: writer,
                                    changes: [{ 'field' => 'status', 'value' => 'wip' }])

    feed = Activity.feed.where(organisation_id: organisation.id)
    expect(feed.where(trackable: project, action: 'tickets_bulk_changed').count).to eq(1)
    expect(feed.where(trackable: tickets.first, action: 'status_changed')).not_to exist
    expect(feed.where(trackable: single, action: 'status_changed')).to exist
    expect(Activity.where(trackable: tickets.first, action: 'status_changed')).to exist, 'the timeline keeps it'
  end

  it 'is used by every reader that shows a feed' do
    readers = %w[app/services/activities/visible_to.rb app/components/dashboard/stats_cards_component.rb]
    readers.each do |path|
      expect(File.read(Rails.root.join(path))).to include('Activity.feed'), "#{path} reads activities for a feed without Activity.feed"
    end
    expect(File.read(Rails.root.join('app/services/ticket_timeline_service.rb'))).not_to include('Activity.feed'),
                                                                                         'the timeline must keep every row'
  end
end

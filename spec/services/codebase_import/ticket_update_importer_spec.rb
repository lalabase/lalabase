# frozen_string_literal: true

require 'rails_helper'

# What: an imported update writes its history (an assignment, a status, a
#       priority) as activities at the time of the update, and tells nobody
#       about it: no outbox event, so no notification and no mail. Activity
#       skips the outbox for an activity marked skip_notifications, "for
#       imported activities"; until 2026-11-27 the importer did not mark them.
# Why:  a notification row stands at the moment its event reached the inbox
#       (Notifications::RowEvents.arrival). An import of a year of history put
#       every imported assignment, status and priority change on top of the
#       inbox of the people it named, under today, as if it had just happened.
RSpec.describe CodebaseImport::TicketUpdateImporter do
  let(:organisation) { create(:organisation) }
  let(:importing_user) { create(:user) }
  let(:assignee) { create(:user, first_name: 'Ada', last_name: 'Beispiel') }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project) }
  let(:updated_at) { Time.zone.parse('2025-11-03 10:00:00') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: assignee, organisation: organisation, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def import(changes)
    described_class.new(ticket, organisation, importing_user)
                   .import_updates([{ id: 7, created_at: updated_at.iso8601, ticket_changes: changes }])
  end

  it 'writes the imported changes at the time of the update and puts none of them in the outbox' do
    import('assignee-id' => ['', 'Ada Beispiel'], 'status-id' => %w[Neu Erledigt], 'priority-id' => %w[Normal Hoch])

    imported = Activity.where(trackable: ticket, created_at: updated_at)
    expect(imported.pluck(:action)).to contain_exactly('assigned', 'status_changed', 'priority_changed')
    expect(imported.find_by(action: 'assigned').secondary).to eq(assignee)
    expect(OutboxEvent.where(activity_id: imported.select(:id))).to be_empty
  end
end

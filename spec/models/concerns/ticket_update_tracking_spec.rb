# frozen_string_literal: true

require 'rails_helper'

# What a ticket update leaves in the activity trail (user report 05.09.2026).
#
# The description is ActionText: editing it changes no ticket column, only
# the rich_text row. Before the fix a description-only edit either left no
# trace at all (same editor - updater_id unchanged) or a raw
# "Updater: <uuid>" details row (different editor). Now the rich-text row
# itself is asked (Trackable#rich_text_changed_attrs) and the ticket names
# the change like a title change: description_changed.
RSpec.describe 'Ticket update tracking' do
  let(:organisation) { create(:organisation) }
  let(:author) { create(:user, first_name: 'Guido', last_name: 'Boyke') }
  let(:editor) { create(:user, first_name: 'Erika', last_name: 'Musterfrau') }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, content: 'Erste Fassung') }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = author
    ticket
  end

  after do
    Current.user = nil
    ActsAsTenant.current_tenant = nil
  end

  it 'records a description edit as description_changed, not as a bare updated' do
    expect do
      ticket.update!(content: 'Zweite Fassung')
    end.to change { ticket.activities.where(action: 'description_changed').count }.by(1)

    expect(ticket.activities.where(action: 'updated')).to be_empty
  end

  it 'says what was updated in the timeline message' do
    ticket.update!(content: 'Zweite Fassung')
    activity = ticket.activities.find_by(action: 'description_changed')

    expect(activity.detailed_message).to include('Beschreibung geändert')
    # No details table: a body has no old/new pair worth showing.
    expect(activity.has_changes?).to be(false)
  end

  it 'records a description edit by ANOTHER person without updater noise' do
    Current.user = editor

    expect do
      ticket.update!(content: 'Dritte Fassung', updater: editor)
    end.to change { ticket.activities.where(action: 'description_changed').count }.by(1)

    activity = ticket.activities.where(action: 'description_changed').order(:created_at).last
    expect(activity.actor).to eq(editor)
    # The updater churn is bookkeeping and never becomes an activity of its own.
    expect(ticket.activities.where(action: 'updated')).to be_empty
  end

  it 'records NO activity when only the updater bookkeeping changed' do
    expect do
      ticket.update!(updater: editor)
    end.not_to(change { ticket.activities.count })
  end

  it 'keeps title and description changes as two named activities' do
    expect do
      ticket.update!(title: 'Neuer Titel', content: 'Vierte Fassung')
    end.to change { ticket.activities.where(action: 'title_changed').count }.by(1)
       .and change { ticket.activities.where(action: 'description_changed').count }.by(1)

    expect(ticket.activities.where(action: 'updated')).to be_empty
  end
end

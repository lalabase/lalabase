# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Activities::ProjectTarget do
  it 'uses the trackable for ordinary object changes' do
    ticket = instance_double(Ticket)
    activity = instance_double(Activity, action: 'status_changed', trackable: ticket)

    expect(described_class.call(activity)).to eq(ticket)
  end

  it 'uses the secondary object for project-scoped creation events' do
    project = instance_double(Project)
    document = instance_double(Document)
    activity = instance_double(Activity, action: 'document_created', trackable: project, secondary: document)

    expect(described_class.call(activity)).to eq(document)
  end
end

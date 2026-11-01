# frozen_string_literal: true

require 'rails_helper'

# What: the inbox project of an organisation. #meeting_inbox is the one reader;
#   an archived project counts as not set and comes back on restore.
# Why: the column alone does not say whether a project still takes meetings, and
#   a client that writes into an archived project would land where nobody looks.
RSpec.describe Organisation, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  it 'has no inbox until one is chosen' do
    expect(organisation.meeting_inbox).to be_nil
    expect(project.meeting_inbox?).to be(false)
  end

  it 'answers the chosen project, and only that one is the inbox' do
    other = create(:project, organisation: organisation)
    organisation.update!(meeting_inbox_project: project)

    expect(organisation.meeting_inbox).to eq(project)
    expect(project.reload.meeting_inbox?).to be(true)
    expect(other.reload.meeting_inbox?).to be(false)
  end

  it 'treats an archived inbox as not set and brings it back on restore' do
    organisation.update!(meeting_inbox_project: project)

    project.archive!(user)
    expect(organisation.reload.meeting_inbox).to be_nil
    expect(organisation.meeting_inbox_project_id).to eq(project.id)
    expect(project.reload.meeting_inbox?).to be(false)

    project.unarchive!
    expect(organisation.reload.meeting_inbox).to eq(project)
  end

  it 'refuses a project of another organisation' do
    foreign = ActsAsTenant.without_tenant { create(:project, organisation: create(:organisation)) }
    organisation.meeting_inbox_project_id = foreign.id

    expect(organisation).not_to be_valid
    expect(organisation.errors.of_kind?(:meeting_inbox_project_id, :not_usable)).to be(true)
  end

  it 'refuses an archived project when it is chosen, not on every later save' do
    organisation.update!(meeting_inbox_project: project)
    project.archive!(user)
    expect(organisation.reload.update(name: 'Neuer Name')).to be(true)

    archived = create(:project, organisation: organisation, archived_at: 1.day.ago)
    organisation.meeting_inbox_project_id = archived.id
    expect(organisation).not_to be_valid
  end

  it 'clears the column when the project is deleted' do
    organisation.update!(meeting_inbox_project: project)
    project.destroy!

    expect(organisation.reload.meeting_inbox_project_id).to be_nil
  end
end

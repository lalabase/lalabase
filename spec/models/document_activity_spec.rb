# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Document Activity Tracking', type: :model do
  include ActionDispatch::TestProcess::FixtureFile
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Current.user = nil
  end

  describe 'when creating a document' do
    it 'creates an activity for the project' do
      document = nil

      # Clear any existing project activities to ensure clean test
      # Use destroy_all to cascade dependent outbox_events and respect FKs
      project.activities.destroy_all

      expect do
        document = create(:document, project: project, creator: user)
      end.to change { project.activities.count }.by(1)

      activity = project.activities.where(action: 'document_created').last
      expect(activity).to be_present
      expect(activity.action).to eq('document_created')
      expect(activity.actor).to eq(user)
      expect(activity.trackable).to eq(project)
      expect(activity.secondary).to eq(document)
    end
  end

  describe 'project activity tracking' do
    it 'tracks document creation in project activities' do
      document = create(:document, project: project, creator: user)

      # Clear existing activities to test project activity tracking specifically
      # Use destroy_all so dependent associations are cleaned up
      Activity.destroy_all

      # Manually trigger the project activity callback to test it works
      document.send(:track_document_created_in_project)

      project_activity = project.activities.last
      expect(project_activity.action).to eq('document_created')
      expect(project_activity.trackable).to eq(project)
      expect(project_activity.secondary).to eq(document)
      expect(project_activity.parameters['creator_name']).to eq(user.full_name)
      # document_title will be nil since document has no current_version
      expect(project_activity.parameters['document_title']).to be_nil
    end
  end
end

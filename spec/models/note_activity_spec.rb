# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Note Activity Tracking', type: :model do
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

  describe 'when creating a note' do
    it 'creates an activity for the project' do
      note = nil

      # Clear any existing project activities to ensure clean test
      project.activities.destroy_all

      expect do
        note = create(:note, project: project, creator: user, title: 'Test Note', content: 'Test content')
      end.to change { project.activities.count }.by(1)

      activity = project.activities.where(action: 'note_created').last
      expect(activity).to be_present
      expect(activity.action).to eq('note_created')
      expect(activity.actor).to eq(user)
      expect(activity.trackable).to eq(project)
      expect(activity.secondary).to eq(note)
    end
  end
end

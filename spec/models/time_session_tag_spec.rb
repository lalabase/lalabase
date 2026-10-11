# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSession, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end
  let(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, active: true)
    end
  end

  before(:each) do
    membership # Create the active membership
    ActsAsTenant.current_tenant = organisation
  end

  after(:each) do
    ActsAsTenant.current_tenant = nil
  end

  describe 'tagging' do
    let(:time_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, project: project, creator: user, organisation: organisation)
      end
    end

    it 'can be tagged with a string' do
      time_session.tag_list = 'important, urgent'
      time_session.save

      expect(time_session.tag_list).to match_array(%w[important urgent])
      expect(time_session.tags.count).to eq(2)
    end

    it 'can be tagged with an array' do
      time_session.tag_list = %w[important urgent]
      time_session.save

      expect(time_session.tag_list).to match_array(%w[important urgent])
      expect(time_session.tags.count).to eq(2)
    end

    it 'can update tags' do
      time_session.tag_list = 'important, urgent'
      time_session.save

      time_session.tag_list = 'important, critical' # Remove urgent, add critical
      time_session.save

      expect(time_session.tag_list).to match_array(%w[important critical])
      expect(time_session.tags.count).to eq(2)
    end

    it 'can find time sessions by tag' do
      time_session.tag_list = 'important'
      time_session.save

      other_session = ActsAsTenant.with_tenant(organisation) do
        create(:time_session, project: project, creator: user, organisation: organisation)
      end
      other_session.tag_list = 'urgent'
      other_session.save

      # Find all time sessions with the tag "important"
      important_sessions = TimeSession.tagged_with('important')

      expect(important_sessions).to include(time_session)
      expect(important_sessions).not_to include(other_session)
    end
  end
end

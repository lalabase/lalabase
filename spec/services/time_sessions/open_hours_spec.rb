# frozen_string_literal: true

require 'rails_helper'

# The request spec (spec/requests/api/v1/time_sessions_open_access_spec.rb)
# owns the rules case by case. This pins what only the object itself shows:
# a reach without organisations means no rows at all, never every row.
RSpec.describe TimeSessions::OpenHours do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        project = create(:project, organisation: organisation)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
        create(:time_session_permission, user: user, project: project, can_view_own: true)
        TimeSession.create!(project: project, organisation: organisation, creator: user,
                            occurred_on: 1.day.ago, duration: 30)
      end
    end
  end

  def call(reach)
    described_class.call(user: user, reach: reach, page: 1, per_page: 25)
  end

  it 'lists nothing when the reach names no organisation' do
    hours = call(PersonalAccessToken::Reach.new(project_ids_by_organisation: {}))

    expect([hours.rows, hours.total, hours.total_minutes, hours.tickets]).to eq([[], 0, 0, {}])
  end

  it 'lists the own open hours of an organisation in reach' do
    hours = call(PersonalAccessToken::Reach.new(project_ids_by_organisation: { organisation.id => nil }))

    expect([hours.rows.size, hours.total, hours.total_minutes]).to eq([1, 1, 30])
  end
end

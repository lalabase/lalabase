# frozen_string_literal: true

require 'rails_helper'

# What: the home of a person in two organisations (ApplicationController#user_home_path),
#       which the bare domain, the way back of the account area and a refused demo action
#       lead to.
# Why:  it read `user.organisations.first`, which sorts by the random UUID. The demo
#       login is a member of two organisations, and a visitor whose action the demo
#       refused could land in the client's instead of Nordlicht.
RSpec.describe 'The home of a person in two organisations', type: :request do
  let(:user) { create(:user) }
  # Without an order, `first` sorts by the random UUID: the later organisation gets the
  # smaller one, so that order picks it.
  let(:joined_first) { create(:organisation, id: 'ffffffff-ffff-4fff-bfff-ffffffffffff', name: 'Zeta GmbH') }
  let(:joined_later) { create(:organisation, id: '00000000-0000-4000-8000-000000000000', name: 'Alpha AG') }

  def join(organisation, at:)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation), active: true, created_at: at)
    end
  end

  before do
    join(joined_later, at: 1.day.ago)
    join(joined_first, at: 1.week.ago)
    ActsAsTenant.current_tenant = nil
    sign_in user
  end

  it 'is the organisation joined first, whatever its id' do
    get root_path

    expect(response).to redirect_to(organisation_root_path(joined_first))
  end
end

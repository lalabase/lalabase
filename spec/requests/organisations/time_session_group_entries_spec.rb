# frozen_string_literal: true

require 'rails_helper'

# What: the fragment listing the bookings a billing already holds.
# Type: Request spec.
# Why:  the assignment panel loads this on demand, in a lazy turbo-frame, so
#       somebody deciding which billing to add time to can look inside first
#       (user, 31.08.2026).
#
#       Two things have to hold and neither is visible in the panel's markup:
#       Pundit derives its question from the ACTION name, so a new action without
#       a predicate raises NoMethodError at request time rather than failing a
#       check; and the rows must be policy-scoped, or a panel would hand somebody
#       who may only see their own hours a list of everybody's.
RSpec.describe 'Organisations::TimeSessionGroups entries', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:colleague) { create(:user) }
  let(:outsider) { create(:user) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:group) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session_group, organisation: organisation, creator: admin, name: 'aug-2026')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
      create(:membership, user: colleague, organisation: organisation, active: true)
    end
    Prosopite.pause
  end

  after { Prosopite.resume }

  def book(minutes, creator:, description:)
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, creator: creator,
                            duration: minutes, occurred_on: Time.utc(2026, 8, 15, 10, 0),
                            description: description, time_session_group: group)
    end
  end

  it 'lists what the billing holds, with the durations' do
    book(45, creator: admin, description: 'Reproduktion und Fix')
    sign_in admin

    get entries_organisation_time_session_group_path(organisation, group)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Reproduktion und Fix')
    expect(response.body).to include('00:45')
  end

  # The frame id has to match the one the panel renders, or Turbo drops the
  # response on the floor and the reader sees "Wird geladen ..." forever.
  it 'answers inside the frame the panel opened' do
    book(30, creator: admin, description: 'Irgendwas')
    sign_in admin

    get entries_organisation_time_session_group_path(organisation, group)

    expect(response.body).to include(%(<turbo-frame id="billing_entries_#{group.id}">))
  end

  it 'says so when the billing is still empty' do
    sign_in admin

    get entries_organisation_time_session_group_path(organisation, group)

    expect(response.body).to include(
      I18n.t('views.organisations.time_sessions.index_table.billing_entries_none')
    )
  end

  # The one that matters. An admin sees both bookings; somebody without the
  # right to see other people's hours must not get them here just because they
  # are inside a billing.
  it 'shows an admin every booking in the billing' do
    book(45, creator: admin, description: 'Von mir')
    book(30, creator: colleague, description: 'Von der Kollegin')
    sign_in admin

    get entries_organisation_time_session_group_path(organisation, group)

    expect(response.body).to include('Von mir')
    expect(response.body).to include('Von der Kollegin')
  end

  # The case the panel actually produces: it offers EVERY open billing as a
  # target, so a member is one click away from a billing they may not look into.
  # The shared Pundit handler redirects, and a redirect to a page without this
  # frame leaves them in front of "Wird geladen ..." for ever. It has to answer
  # inside the frame, and say what happened.
  it 'refuses inside the frame when a member may not look into this billing' do
    book(45, creator: admin, description: 'Nicht fuer dich')
    sign_in colleague

    get entries_organisation_time_session_group_path(organisation, group)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).to include(%(<turbo-frame id="billing_entries_#{group.id}">))
    expect(response.body).to include(
      I18n.t('views.organisations.time_sessions.index_table.billing_entries_denied')
    )
    expect(response.body).not_to include('Nicht fuer dich')
  end

  # This proves the TENANT boundary, not the policy: an outsider never reaches
  # Pundit, because the billing is not findable for them in the first place.
  # Probed by making entries? return true, which changes nothing here. What
  # entries? answers is pinned where it can be: spec/policies.
  it 'is not even findable for somebody outside the organisation' do
    book(45, creator: admin, description: 'Von mir')
    sign_in outsider

    get entries_organisation_time_session_group_path(organisation, group)

    # Only the status. The exception page renders THIS FILE's source, so a
    # "body does not contain the description" assertion passes or fails on
    # whether the string appears in the spec, not on what leaked. That is
    # exactly how the first version of this example was green for the wrong
    # reason.
    expect(response).to have_http_status(:not_found)
  end

  # The leak this endpoint could be: a colleague who may see only their OWN
  # hours has every right to look inside a billing they contributed to, and no
  # right to read everybody else's rows while they are in there.
  it 'scopes the rows to what the reader may see, inside their own billing' do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session_permission, user: colleague, project: project,
                                       can_view_own: true, can_view_all: false)
    end
    book(45, creator: admin, description: 'Von der Chefin')
    book(30, creator: colleague, description: 'Von mir selbst')
    sign_in colleague

    get entries_organisation_time_session_group_path(organisation, group)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Von mir selbst')
    expect(response.body).not_to include('Von der Chefin')
  end
end

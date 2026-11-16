# frozen_string_literal: true

# The people above the organisations (GET /people): one list over the people of every
# organisation a person is an active member of, beside the inbox above them. Read only:
# search, an organisation to narrow to, pages. A row of one organisation leads to that
# organisation's people page with the person open; a person of several organisations
# leads there through the chip of each.
#
# Runs WITHOUT a tenant, like the inbox above the organisations, and never sets the
# session's organisation. `org` (one organisation of the list) is therefore not called
# organisation_id, the name ApplicationController reads the tenant from.
#
# The rows come from People::AcrossOrganisations: per organisation under its own tenant,
# through People::Lookup, and only where the person holds the people right. That read is
# the authorization of this page (PersonPolicy.view_allowed? per organisation); the
# action asks no policy of its own, as the inbox above the organisations asks none.
#
# ⚠️ Everything a row shows is a plain value the read handed out. The views run after it,
# without a tenant: a tenanted model read there raises NoTenantSet.
class AllPeopleController < ApplicationController
  skip_before_action :load_tenant_from_session

  LIST_FRAME_ID = 'all_people_results'

  # An organisation the person cannot reach, one without the people right, one that does
  # not exist and a malformed id answer alike.
  rescue_from People::AcrossOrganisations::UnknownOrganisation do
    head :not_found
  end

  def index
    return redirect_to(single_people_path) if single_people_path

    @people = People::AcrossOrganisations.call(viewer: current_user, query: params[:q], org: params[:org],
                                               page: params[:page])
  end

  private

  # This page stands above the organisations: no assistant, no page context
  # (ApplicationController#assistant_available?).
  def page_above_organisations?
    true
  end

  # With fewer than two organisations there is nothing above them: the people page of the
  # one organisation, or wherever a person without any belongs.
  def single_people_path
    return @single_people_path if defined?(@single_people_path)

    organisations = current_user.active_organisations.limit(2).to_a
    @single_people_path =
      case organisations.size
      when 0 then user_home_path(current_user)
      when 1 then organisation_people_path(organisations.first)
      end
  end
end

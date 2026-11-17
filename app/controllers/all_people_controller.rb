# frozen_string_literal: true

# The people above the organisations (GET /people): one list over the people of every
# organisation a person is an active member of, beside the inbox above them, and the card
# of one person in the lane beside it. Read only: search, an organisation to narrow to,
# pages, and for one person what every organisation knows about them, side by side.
#
# Runs WITHOUT a tenant, like the inbox above the organisations, and never sets the
# session's organisation. `org` (one organisation of the list) and `card` (one person:
# "<organisation id>:<entry address>" of any of their sources) are therefore not called
# organisation_id, the name ApplicationController reads the tenant from.
#
# The rows come from People::AcrossOrganisations and the card from People::MergedCard: per
# organisation under its own tenant, through People::Lookup, and only where the person
# holds the people right. That read is the authorization of this page
# (PersonPolicy.view_allowed? per organisation; for the card also PersonPolicy#update?,
# asked under the tenant and handed out as a flag); the actions ask no policy of their
# own, as the inbox above the organisations asks none.
#
# The lane is this page's own address: a request with the lane's frame header answers the
# card alone, the same address without it the page with the lane open. An address that
# names nobody the viewer can see (unknown, another organisation's, one without the
# right, malformed) answers ONE body in the lane (404) and is no state of the page. A
# source the viewer may not read is absent from a card with everything it holds.
#
# Nothing is edited here. A pencil of the card is a visit of the people page of that
# organisation (its lane state ?edit=), where the rights, the form and the save are.
#
# ⚠️ Everything the list and the card show is a plain value the read handed out. The
# views run after it, without a tenant: a tenanted model read there raises NoTenantSet.
class AllPeopleController < ApplicationController
  skip_before_action :load_tenant_from_session

  LIST_FRAME_ID = 'all_people_results'
  CARD_FRAME_ID = 'all_people_card'
  # The lane state: the person whose card is open.
  CARD_PARAM = 'card'
  # "Bearbeiten" is on for the card that is open: every value names its organisations,
  # and with them the pencils. A state of the request, not remembered.
  EDITING_PARAM = 'editing'

  # An organisation the person cannot reach, one without the people right, one that does
  # not exist and a malformed id answer alike.
  rescue_from People::AcrossOrganisations::UnknownOrganisation do
    head :not_found
  end

  def index
    return redirect_to(single_people_path) if single_people_path
    return render_card if turbo_frame_request_id == CARD_FRAME_ID

    across = People::AcrossOrganisations.new(viewer: current_user, query: params[:q], org: params[:org], page: params[:page])
    @people = across.call
    # The card reads through the list's read: one directory per organisation and request.
    @card = People::MergedCard.call(viewer: current_user, address: params[CARD_PARAM], across: across)
  end

  # PATCH /people/sources: "Quellen zeigen" on or off, for the person. A view option, one
  # write without side effects, as the cockpit's settings above the organisations: it
  # stays in the controller. Only a word counts as a value; back to the card it came from.
  def sources
    shown = params[:show]
    current_user.preference_store.remember_people_card_sources(shown.is_a?(String) && ActiveModel::Type::Boolean.new.cast(shown) == true)
    redirect_to all_people_path(card_state), status: :see_other
  end

  private

  # This page stands above the organisations: no assistant, no page context
  # (ApplicationController#assistant_available?).
  def page_above_organisations?
    true
  end

  # The lane alone. Whatever the address does not name is the same answer.
  def render_card
    card = People::MergedCard.call(viewer: current_user, address: params[CARD_PARAM])
    render html: helpers.turbo_frame_tag(CARD_FRAME_ID) {
      helpers.render(partial: 'all_people/lane', locals: { card: card, missing: card.nil? })
    }, layout: false, status: card ? :ok : :not_found
  end

  # The card a switch came from, as the lane state of the way back.
  def card_state
    card = params[CARD_PARAM]
    state = {}
    state[CARD_PARAM] = card if card.is_a?(String) && card.present?
    state[EDITING_PARAM] = 1 if state.any? && params[EDITING_PARAM] == '1'
    state
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

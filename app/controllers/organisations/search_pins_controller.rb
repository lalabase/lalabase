# frozen_string_literal: true

module Organisations
  # Toggles the per-user, per-org "pin global search as a persistent inline bar"
  # preference. Trivial single write (no side effects) -> stays in the controller.
  class SearchPinsController < BaseController
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped

    SEARCH_PIN_KEY = 'search'

    def update
      # Same gate as the search feature in the layout/overlay (single source in
      # ApplicationController) — don't let a user pin a feature they can't use.
      return head :forbidden unless global_search_available?

      if current_user.sidebar_pins.global_pinned?(current_organisation, SEARCH_PIN_KEY)
        current_user.sidebar_pins.unpin_global!(current_organisation, SEARCH_PIN_KEY)
      else
        current_user.sidebar_pins.pin_global!(current_organisation, SEARCH_PIN_KEY)
      end

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            'global-search-nav',
            partial: 'common/global_search_nav_item'
          )
        end
        format.html { redirect_to organisation_root_path(organisation_id: current_organisation.id) }
      end
    end
  end
end

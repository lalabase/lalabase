# frozen_string_literal: true

# Dismisses the onboarding banner on the organisation overview (Kettenglied 0,
# doc/onboarding_plan.md D4). Dismissal is a personal per-user+org preference —
# the tutorial project itself stays untouched and remains reachable via the
# project list / my_open_tickets widget.
module Organisations
  class OnboardingBannersController < BaseController
    # Personal preference write only — no domain record, no policy object
    # (same skip pattern as the briefings overview this banner lives on).
    skip_after_action :verify_authorized

    def destroy
      current_user.preference_store.dismiss_onboarding_banner!(@current_organisation)
      redirect_to organisation_root_path(@current_organisation)
    end
  end
end

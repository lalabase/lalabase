# frozen_string_literal: true

module Organisations
  # Per-user org recognition color (see OrgColor / User::OrgColorSettings#set). DELIBERATELY NO Pundit:
  # each user controls only their own view (no org-wide effect) -> no authz gate.
  class AppearancesController < BaseController
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped

    def show
      # Palette = OrgColor::PALETTE (the only source; "Automatic"/"Off" are modes alongside it).
      @presets = OrgColor::PALETTE
      # Raw setting: hex (a single color), OrgColor::OFF (off) or nil (automatic).
      @current_setting = current_user.org_colors.setting_for(@current_organisation)
    end

    def update
      apply_org_color(params[:org_color])
      redirect_to organisation_root_path(@current_organisation), notice: t('.saved')
    end

    private

    # 3-state, whitelisted against OrgColor (no free-form hex):
    #   Palette hex      -> this color
    #   OrgColor::OFF    -> DELIBERATELY off
    #   otherwise ("auto"/empty/unknown) -> reset + immediately assign a system color,
    #     so that "Automatic" does not end up in a colorless intermediate state (ensure_ is
    #     idempotent and assigns a palette color distinct from the other orgs).
    def apply_org_color(value)
      if OrgColor::HEXES.include?(value)
        current_user.org_colors.set(@current_organisation, value)
      elsif value == OrgColor::OFF
        current_user.org_colors.set(@current_organisation, OrgColor::OFF)
      else
        current_user.org_colors.set(@current_organisation, :auto)
        current_user.org_colors.ensure_defaults!
      end
    end
  end
end

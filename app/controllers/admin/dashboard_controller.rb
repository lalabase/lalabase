# frozen_string_literal: true

module Admin
  class DashboardController < Admin::ApplicationController
    def index
      # Counts for the Verwaltung tiles. A tile that comes in through the slot
      # :dashboard_management_tiles counts for itself (Lalabase::AdminExtensions).
      @organisation_count = Organisation.count
      @user_count = User.count
      @admin_count = Beuser.where(role: 'admin').count
    end
  end
end

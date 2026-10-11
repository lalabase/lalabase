# frozen_string_literal: true

# Bridge controller for Mission Control Jobs integration
# This will be used as the base_controller_class for Mission Control Jobs
# All Mission Control controllers will inherit from this instead of ApplicationController
class Admin::MissionControlController < Admin::ApplicationController
  # Override logged_in? to handle Mission Control Jobs parameters properly
  def logged_in?
    unless current_user
      # Use string URL to avoid route generation issues with Mission Control parameters
      redirect_to '/admin/log_in'
      return false
    end
    true
  end
end

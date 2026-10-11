# frozen_string_literal: true

module Organisations
  class MobileNavigationController < BaseController
    def projects
      authorize current_organisation, :show?
      render partial: 'layouts/mobile_project_switcher' if turbo_frame_request? && request.headers['Turbo-Frame'] == 'mobile_project_switcher'
    end

    def more
      authorize current_organisation, :show?
    end
  end
end

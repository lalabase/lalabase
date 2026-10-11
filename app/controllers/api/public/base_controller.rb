# frozen_string_literal: true

module Api
  module Public
    # API-only base for unauthenticated, read-only public endpoints.
    class BaseController < ActionController::API
    end
  end
end

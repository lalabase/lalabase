# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public API contract guard' do
  def public_api_routes
    Rails.application.routes.routes.select do |route|
      route_path(route).start_with?('/api/public/')
    end
  end

  def route_path(route)
    "/#{route.path.spec.to_s.delete_prefix('/')}"
  end

  def controller_class(route)
    "#{route.defaults.fetch(:controller).camelize}Controller".constantize
  end

  it 'keeps every public API route read-only' do
    expect(public_api_routes).not_to be_empty
    expect(public_api_routes.map(&:verb).uniq).to eq(['GET'])
  end

  it 'routes every public endpoint through the isolated API-only controller base' do
    expect(Api::Public::BaseController.superclass).to eq(ActionController::API)

    forbidden_ancestors = [Api::TokenAuthenticatable, Pundit::Authorization, ActionController::Base]
    public_api_routes.each do |route|
      klass = controller_class(route)
      base_failure = "#{klass} must inherit from Api::Public::BaseController"
      auth_failure = "#{klass} inherited authenticated controller behavior"

      expect(klass < Api::Public::BaseController).to be(true), base_failure
      expect(klass.ancestors & forbidden_ancestors).to be_empty, auth_failure
    end
  end

  it 'does not expose format-suffixed variants as part of the public v1 contract' do
    expect do
      Rails.application.routes.recognize_path('/api/public/v1/price_list.json', method: :get)
    end.to raise_error(ActionController::RoutingError)
  end
end

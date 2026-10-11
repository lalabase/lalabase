# frozen_string_literal: true

require 'rails_helper'

# The provisioning namespace is the one place where a caller without an account
# writes to the core. What holds it shut is structural, so the guard reads the
# classes rather than the source text.
RSpec.describe 'Provisioning API contract guard' do
  def provisioning_routes
    Rails.application.routes.routes.select do |route|
      "/#{route.path.spec.to_s.delete_prefix('/')}".start_with?('/api/provisioning/')
    end
  end

  def controller_class(route)
    "#{route.defaults.fetch(:controller).camelize}Controller".constantize
  end

  it 'routes every provisioning endpoint through the isolated API-only base' do
    expect(provisioning_routes).not_to be_empty
    expect(Api::Provisioning::BaseController.superclass).to eq(ActionController::API)

    forbidden_ancestors = [Api::TokenAuthenticatable, Pundit::Authorization, ActionController::Base]
    provisioning_routes.each do |route|
      klass = controller_class(route)

      expect(klass < Api::Provisioning::BaseController).to be(true),
                                                           "#{klass} must inherit from Api::Provisioning::BaseController"
      expect(klass.ancestors & forbidden_ancestors).to be_empty,
                                                       "#{klass} inherited authenticated controller behavior"
    end
  end

  it 'checks the secret before every provisioning action' do
    provisioning_routes.each do |route|
      callbacks = controller_class(route)._process_action_callbacks
                                         .select { |callback| callback.kind == :before }
                                         .map(&:filter)

      expect(callbacks).to include(:ensure_provisioning_enabled, :authenticate_website),
                           "#{controller_class(route)} runs without the shared-secret gate"
    end
  end

  it 'does not expose format-suffixed variants as part of the contract' do
    expect do
      Rails.application.routes.recognize_path('/api/provisioning/v1/signups.json', method: :post)
    end.to raise_error(ActionController::RoutingError)
  end
end

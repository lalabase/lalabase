# frozen_string_literal: true

require 'rails_helper'

# What: the sign-in door of clients (/api/auth/) keeps a base of its own.
# Why: it is the one place where a program sends a password without holding a token.
#   A controller there that inherited the token base would ask for a token nobody has;
#   one that inherited the base of the pages would bring cookies, CSRF and a session.
#   And a route with a format would be a second address the brake has to know.
#   The classes are checked, not the text of the files.
RSpec.describe 'Auth API contract guard', :ci_guard do
  def route_path(route)
    "/#{route.path.spec.to_s.delete_prefix('/')}"
  end

  def auth_api_routes
    Rails.application.routes.routes.select { |route| route_path(route).start_with?('/api/auth/') }
  end

  def controller_class(route)
    "#{route.defaults.fetch(:controller).camelize}Controller".constantize
  end

  def controller_files
    Rails.root.glob('app/controllers/api/auth/**/*_controller.rb')
  end

  def class_of(file)
    file.relative_path_from(Rails.root.join('app/controllers')).to_s.delete_suffix('.rb').camelize.constantize
  end

  it 'finds the routes and the controllers it is meant to check' do
    expect(auth_api_routes.map { |route| "#{route.verb} #{route_path(route)}" })
      .to contain_exactly('GET /api/auth/v1/methods', 'POST /api/auth/v1/app_sessions')
    expect(controller_files.map { |file| file.basename.to_s })
      .to contain_exactly('base_controller.rb', 'methods_controller.rb', 'app_sessions_controller.rb')
  end

  it 'keeps the base API-only: no token authentication, no Pundit, no page base' do
    expect(Api::Auth::BaseController.superclass).to eq(ActionController::API)
    expect(Api::Auth::BaseController.ancestors)
      .not_to include(Api::TokenAuthenticatable, Pundit::Authorization, ActionController::Base, Api::V1::Idempotent)
  end

  it 'routes every endpoint through that base' do
    auth_api_routes.each do |route|
      klass = controller_class(route)

      expect(klass < Api::Auth::BaseController).to be(true), "#{klass} must inherit from Api::Auth::BaseController"
    end
  end

  # A controller file without a route is checked as well: the next endpoint is a
  # file first.
  it 'lets every controller under api/auth descend from the base and from nothing that knows a token' do
    forbidden = [Api::TokenAuthenticatable, Pundit::Authorization, ActionController::Base, Api::V1::Idempotent,
                 Api::V1::BaseController]

    controller_files.each do |file|
      klass = class_of(file)

      expect(klass <= Api::Auth::BaseController).to be(true), "#{klass} must descend from Api::Auth::BaseController"
      expect(klass.ancestors & forbidden).to be_empty, "#{klass} inherited authenticated controller behaviour"
    end
  end

  it 'keeps no copy of the body under the name of the controller' do
    controller_files.each do |file|
      expect(class_of(file)._wrapper_options.format).to be_empty, "#{class_of(file)} wraps its parameters"
    end
  end

  it 'refuses a format on every route' do
    auth_api_routes.each do |route|
      expect(route.path.spec.to_s).not_to include('(.:format)'), "#{route_path(route)} takes a format"
    end

    expect { Rails.application.routes.recognize_path('/api/auth/v1/methods.json', method: :get) }
      .to raise_error(ActionController::RoutingError)
    expect { Rails.application.routes.recognize_path('/api/auth/v1/app_sessions.json', method: :post) }
      .to raise_error(ActionController::RoutingError)
    expect(Rails.application.routes.recognize_path('/api/auth/v1/app_sessions', method: :post))
      .to eq(controller: 'api/auth/v1/app_sessions', action: 'create')
  end

  # The demo bar stands in the base, so a new endpoint has it unless it says
  # otherwise. Only the methods say otherwise, and they offer no method there.
  it 'shuts every endpoint but the methods in the public demo' do
    classes = controller_files.map { |file| class_of(file) }

    classes.each do |klass|
      expect(klass._process_action_callbacks.map(&:filter)).to include(:refuse_in_demo_mode),
                                                               "#{klass} skips the demo bar"
    end
    expect(classes.select { |klass| klass.new.send(:answers_in_demo?) }).to eq([Api::Auth::V1::MethodsController])
  end
end

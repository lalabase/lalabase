# frozen_string_literal: true

require 'rails_helper'

# Guard for the API's Pundit tripwire (Api::V1::BaseController):
# verify_authorized/verify_policy_scoped ensure that a new endpoint
# without explicit authorization fails loudly instead of silently returning 200.
# This spec breaks if (a) someone removes the guards in the BaseController or
# (b) a Pundit-required controller disables them via skip_after_action.
# Allowed opt-outs (authorization = token scope, commented in the controller):
# me, notifications, organisations.
RSpec.describe 'Api::V1 Pundit-Tripwire' do
  def after_action_filters(controller_class)
    controller_class._process_action_callbacks
                    .select { |callback| callback.kind == :after }
                    .map(&:filter)
  end

  it 'erzwingt verify_authorized und verify_policy_scoped im BaseController' do
    expect(after_action_filters(Api::V1::BaseController))
      .to include(:verify_authorized, :verify_policy_scoped)
  end

  it 'lässt die Pundit-pflichtigen Controller den Tripwire nicht aushebeln' do
    [
      Api::V1::TicketsController,
      Api::V1::ProjectsController,
      Api::V1::PostsController,
      Api::V1::TimeSessionsController
    ].each do |controller|
      expect(after_action_filters(controller))
        .to include(:verify_authorized, :verify_policy_scoped),
            "#{controller} hebelt den Pundit-Tripwire aus (skip_after_action?) — " \
            'nur token-scope-autorisierte Controller dürfen das, mit Kommentar.'
    end
  end
end

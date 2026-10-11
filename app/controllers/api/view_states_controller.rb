# frozen_string_literal: true

class Api::ViewStatesController < ApplicationController
  ALLOWED_VIEWABLE_TYPES = %w[Organisation Project Ticket Note Document].freeze

  before_action :authenticate_user!
  skip_before_action :verify_authenticity_token, if: :json_request?

  def show
    view_state = find_or_initialize_view_state
    render json: { state: view_state.state }
  end

  def update
    view_state = find_or_initialize_view_state

    if view_state.update(state: view_state.state.merge(state_params))
      render json: { state: view_state.state }
    else
      render json: { errors: view_state.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def find_or_initialize_view_state
    viewable = find_viewable

    ViewState.find_or_initialize_by(
      user: current_user,
      key: params[:id],
      viewable: viewable,
      organisation: current_organisation
    )
  end

  def find_viewable
    if params[:viewable_type].present? && params[:viewable_id].present?
      viewable_type = params[:viewable_type]
      raise ActiveRecord::RecordNotFound, 'Invalid viewable type' unless ALLOWED_VIEWABLE_TYPES.include?(viewable_type)

      # acts_as_tenant automatically scopes find() to the current organisation.
      # authorize ensures the user has access to the specific object.
      viewable = viewable_type.constantize.find(params[:viewable_id])
      authorize viewable, :show?
      viewable
    else
      current_organisation
    end
  end

  # Only allow scalar values (no nested hashes/arrays)
  def state_params
    return {} unless params[:state].is_a?(ActionController::Parameters)

    permitted = {}
    params[:state].each_pair do |key, value|
      permitted[key.to_s] = value if value.is_a?(String) || value.is_a?(Numeric) || value.in?([true, false])
    end
    permitted
  end

  def json_request?
    request.format.json?
  end
end

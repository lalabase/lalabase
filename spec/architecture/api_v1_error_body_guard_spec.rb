# frozen_string_literal: true

require 'rails_helper'

# What: no /api/v1 controller or concern builds an error body by hand; every one
#   goes through Api::V1::BaseController#render_error (Api::V1::ErrorBody).
# Why: the error code (`code`, cli_rest_plan D6) is only as reliable as its
#   coverage. A controller that renders `{ error: ... }` itself answers without
#   `code`, and a client that branches on it misreads the answer. The rule has to
#   hold for the next endpoint as well, so the hand-built body is what this guard
#   refuses.
module ApiV1ErrorBodyGuard
  GLOBS = %w[app/controllers/api/v1/**/*.rb app/controllers/concerns/api/v1/**/*.rb].freeze
  OWNER = 'app/controllers/concerns/api/v1/error_body.rb'

  # A render with an `error` key or an `errors` key, on one line or wrapped.
  HAND_BUILT = /render\s*\(?\s*json:\s*\{[^}]*\berrors?:/m

  def self.offences
    GLOBS.flat_map { |glob| Rails.root.glob(glob) }.filter_map do |path|
      relative = path.relative_path_from(Rails.root).to_s
      next if relative == OWNER

      relative if path.read.match?(HAND_BUILT)
    end
  end
end

RSpec.describe 'API V1 error body guard', :ci_guard do
  it 'finds the files it is meant to scan' do
    files = ApiV1ErrorBodyGuard::GLOBS.flat_map { |glob| Rails.root.glob(glob) }
    expect(files.map { |f| f.basename.to_s }).to include('base_controller.rb', 'tickets_controller.rb', 'error_body.rb')
  end

  it 'recognises a hand-built error body, wrapped or not' do
    expect("render json: { error: 'forbidden' }, status: :forbidden").to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render json: { data: x, errors: e },\n  status: :ok").to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render json: {\n  error: result.code\n}").to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render json: { data: rows }').not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render_error(error: 'forbidden', status: :forbidden)").not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
  end

  it 'leaves every error body to render_error' do
    expect(ApiV1ErrorBodyGuard.offences).to be_empty
  end
end

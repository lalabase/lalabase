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

  # The two renders whose status is a variable by design, each named by the
  # line it may contain. Anything else in these files is still checked.
  ALLOWED_LINES = {
    'app/controllers/api/v1/base_controller.rb' =>
      'render json: Api::V1::ErrorBody.build(error: error, code: code, **extra), status: status',
    'app/controllers/concerns/api/v1/idempotent.rb' =>
      "render json: answer.fetch('body'), status: answer.fetch('status')"
  }.freeze

  # Every error status Rack knows by name, and any 4xx/5xx number.
  ERROR_STATUS = (Rack::Utils::SYMBOL_TO_STATUS_CODE.select { |_name, code| code >= 400 }.keys.map(&:to_s) +
                  ['[45]\\d\\d']).join('|')
  SUCCESS_STATUS = 'ok|created|accepted|no_content|2\\d\\d'

  # Any of:
  # * a render with an `error`/`errors` key, one line or wrapped;
  # * a string or symbol key: `"error" =>`, `"error":`, `:error =>`;
  # * a bodyless `head` with an error status;
  # * a plain `render` (not `render_error`) whose `status:`, on its line or a
  #   continuation line after a comma, is anything but a success status: an
  #   error symbol, a number, or a variable such as a status lookup.
  HAND_BUILT = Regexp.union(
    /render\s*\(?\s*json:\s*\{[^}]*\berrors?:/m,
    /["']errors?["']\s*(?:=>|:)/,
    /:errors?\s*=>/,
    /\bhead\s*\(?\s*:?(?:#{ERROR_STATUS})\b/,
    /\brender(?!_)\b(?:[^\n]*,[ \t]*\n)*[^\n]*\bstatus:[ \t]*(?![ \t])(?!:?(?:#{SUCCESS_STATUS})\b)/
  )

  def self.offences
    GLOBS.flat_map { |glob| Rails.root.glob(glob) }.filter_map do |path|
      relative = path.relative_path_from(Rails.root).to_s
      next if relative == OWNER

      source = path.read
      source = source.sub(ALLOWED_LINES[relative], '') if ALLOWED_LINES.key?(relative)
      relative if source.match?(HAND_BUILT)
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
    expect("render json: { 'error' => 'x' }").to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render status: :not_found, json: body').to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render json: body, status: 422').to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('head :forbidden').to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render json: { data: rows }').not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render json: { data: row }, status: :created').not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render json: { message: x },\n  status: :forbidden").to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render json: { "error": "x" }, status: http_status').to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render json: { :error => 'x' }").to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('render json: x, status: ACTOR_ERROR_STATUS.fetch(c)').to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('head :too_many_requests').to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render json: { data: row },\n  status: :created").not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect('head :ok').not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
    expect("render_error(error: 'forbidden', status: :forbidden)").not_to match(ApiV1ErrorBodyGuard::HAND_BUILT)
  end

  it 'still finds each allowed line, so an allowance cannot outlive its code' do
    ApiV1ErrorBodyGuard::ALLOWED_LINES.each do |file, line|
      expect(Rails.root.join(file).read).to include(line), "#{file} no longer contains the allowed render"
    end
  end

  it 'leaves every error body to render_error' do
    expect(ApiV1ErrorBodyGuard.offences).to be_empty
  end
end

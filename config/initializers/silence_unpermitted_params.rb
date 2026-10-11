# frozen_string_literal: true

# Log unpermitted parameters (default behavior for development/production)
ActionController::Parameters.action_on_unpermitted_parameters = :log

# Thread-safe: Always permit common pagination and sorting parameters across all controllers.
# Unlike mutating action_on_unpermitted_parameters per-request, this is safe under Puma threads.
ActionController::Parameters.always_permitted_parameters =
  ActionController::Parameters.always_permitted_parameters + %w[page limit items project_id sort column direction]

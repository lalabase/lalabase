# frozen_string_literal: true

# Wires DirectUploadsGuard (app/controllers/concerns) into Rails' own
# ActiveStorage::DirectUploadsController, which lives outside the app's controller
# tree and therefore outside ApplicationController's authentication. Why the guard is
# needed at all: see the concern. Sibling of active_storage_tenant_patch.rb, same
# to_prepare pattern so the include survives code reloading in development.
Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.include(DirectUploadsGuard) unless ActiveStorage::DirectUploadsController < DirectUploadsGuard
end

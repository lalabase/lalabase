# frozen_string_literal: true

# Closes the open direct-upload endpoint (finding F5 in doc/inline_bilder_spike_plan.md).
#
# ActiveStorage::DirectUploadsController inherits from ActionController::Base, not from
# ApplicationController, so none of the app's before_actions ever ran for it: an
# anonymous POST to /rails/active_storage/direct_uploads created a blob row plus a
# signed PUT URL for the file, with no type or size check. Every blob created that way
# is disk space a stranger can fill; UnattachedBlobPurgeJob only sweeps it seven days
# later. Included into the controller by config/initializers/direct_uploads_guard.rb.
#
# Two rules, both at the endpoint, independent of the eight direct-upload forms:
# a signed-in user (Devise scope :user; the admin area does not direct-upload) and an
# upper bound on byte_size. Type rules do NOT belong here: the same endpoint serves
# documents (PDF, Office) and codebase archives, so "images only" is a rule of the
# carrier (rich-text embed validator, spike plan E1), not of the upload.
module DirectUploadsGuard
  extend ActiveSupport::Concern

  # Ceiling of a single direct upload, derived from the largest legitimate direct-upload
  # case in the app: the codebase import sends its ARCHIVE (tar/zip, up to 1 GB) through
  # this endpoint and attaches it in a later request via archive_file_blob_id. The XML
  # limit CodebaseImportFile::MAX_FILE_SIZE (50 MB) is NOT the reference, that file goes
  # through a plain form upload. Deriving instead of repeating keeps one owner; a lower
  # number here would silently break archive imports (guard: direct_uploads_guard_spec).
  MAX_BYTE_SIZE = [CodebaseImportFile::MAX_TAR_FILE_SIZE, CodebaseImportFile::MAX_ZIP_FILE_SIZE].max

  included do
    before_action :require_signed_in_user
    before_action :reject_oversized_blob
  end

  private

  def require_signed_in_user
    head :unauthorized unless user_signed_in?
  end

  # Reads byte_size only when `blob` is the nested hash Rails expects; a scalar or
  # array there is left to ActiveStorage's own `params.expect`, which answers 400
  # instead of the 500 that `params.dig` raised on a String (TypeError).
  def reject_oversized_blob
    return if declared_byte_size <= MAX_BYTE_SIZE

    head :unprocessable_entity
  end

  def declared_byte_size
    blob = params[:blob]
    return 0 unless blob.is_a?(ActionController::Parameters)

    blob[:byte_size].to_s.to_i
  end
end

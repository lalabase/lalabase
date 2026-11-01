# frozen_string_literal: true

module Organisations
  # Authorized file proxy for ActiveStorage attachments.
  #
  # Why: The default blob route serves files only against a signed link —
  # without Devise auth, without Pundit, without tenant. These links never expired,
  # so a once-leaked link opened the file permanently, across project/org boundaries.
  #
  # This controller inherits from Organisations::BaseController and therefore runs WITH Devise auth
  # and a set tenant: record lookups are automatically org-scoped (cross-org => 404),
  # and delivery happens only after a Pundit check of the owning record.
  class FileDownloadsController < Organisations::BaseController
    include ActiveStorage::Streaming

    # Whitelist of deliverable attachments. Per `kind`: model, attachment name and the
    # Pundit target resolver (owning record -> policy). An unknown `kind` leads to 404 —
    # a raw model name or a signed_id from the params is NEVER resolved, only
    # these explicitly allowed types. Phase 2 adds post_document/ticket_document here.
    # The model is a lambda returning the class, not a name: nothing here is ever
    # turned into a constant from a string (and reloading stays safe in development).
    DOWNLOADABLES = {
      'document_version' => {
        model: -> { DocumentVersion },
        attachment: :document_version_file,
        authorize_target: ->(record) { record.document }
      },
      # A comment's attachment is as readable as the comment: PostPolicy#show?
      # (area :tickets, then Post#readable_by? for private comments).
      'post_document' => {
        model: -> { PostDocument },
        attachment: :post_document_file,
        authorize_target: ->(record) { record.post }
      },
      # Ticket documents hang off the ticket → TicketPolicy#show? (area :tickets).
      'ticket_document' => {
        model: -> { TicketDocument },
        attachment: :ticket_document_file,
        authorize_target: ->(record) { record.ticket }
      },
      # An image of a synced documentation page is as readable as the documentation:
      # DocumentationSetPolicy#show? (area :documentation). The cached page HTML holds
      # this address by id and without a signature, so every request is checked here.
      # `version` lets the browser keep the file for a moment (VERSIONED_MAX_AGE): the
      # address does not change when the file does, the version does.
      'documentation_asset' => {
        model: -> { DocumentationAsset },
        attachment: :file,
        authorize_target: ->(record) { record.documentation_set },
        version: ->(record) { record.git_blob_sha }
      }
    }.freeze

    # How long a browser may show a versioned file without asking. Short, because the
    # address stays the same when the file changes; after that it asks with the ETag and
    # gets a 304. One image is one request through Rails, and the general throttle counts
    # each (rack_attack, requests/ip): a page with thirty images must not cost thirty
    # requests on every visit.
    VERSIONED_MAX_AGE = 5.minutes

    # Missing access, unknown kind and foreign/tampered IDs all respond UNIFORMLY
    # with 404 — so the response does not reveal the existence of foreign files (no 403/404 leak).
    rescue_from Pundit::NotAuthorizedError, with: :not_found
    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    # A record whose file is gone from the service answers like a record that
    # is not there. send_blob_stream rescues this itself; the byte-range road
    # (download_chunk) does not, and answered 500 for a file that vanished
    # with a deleted worktree's storage/ (doc/dateivorschau_plan.md, S1).
    rescue_from ActiveStorage::FileNotFoundError, with: :not_found

    def show
      config = DOWNLOADABLES.fetch(params[:kind]) { raise ActiveRecord::RecordNotFound }

      record = config.fetch(:model).call.find(params[:id])
      # Reading the file = being allowed to read the owning record: uniformly `show?` of the
      # associated policy (e.g. DocumentPolicy#show? -> project read access in the documents area).
      authorize config.fetch(:authorize_target).call(record), :show?

      attachment = record.public_send(config.fetch(:attachment))
      raise ActiveRecord::RecordNotFound unless attachment.attached?

      # AFTER the right and the file were checked: a 304 is an answer about this file too.
      return if fresh_version?(config, record)

      # Streams from the service (no full load into memory); content type and
      # filename come from the blob metadata. We REQUEST inline so previewable
      # files (PDF, images) open in the browser instead of force-downloading.
      # Rails keeps the final say on safety: send_blob_stream applies
      # blob.forced_disposition_for_serving, which overrides us back to :attachment
      # for every type NOT in ActiveStorage.content_types_allowed_inline — i.e.
      # script-capable uploads (text/html, image/svg+xml, xml, ...) are ALWAYS
      # downloaded, never rendered inline from our origin. So this restores preview
      # UX without re-opening the stored-XSS hole this proxy was built to close.
      #
      # A Range request gets the bytes it names (doc/dateivorschau_plan.md, D5):
      # 206 with Content-Range for a valid range, 416 for an invalid one, the
      # same 404s before it; the full answer says Accept-Ranges so a viewer in a
      # frame may ask. Bytes, not pages: what a viewer fetches is its business.
      if request.headers['Range'].present?
        send_blob_byte_range_data(attachment.blob, request.headers['Range'], disposition: 'inline')
      else
        response.headers['Accept-Ranges'] = 'bytes'
        send_blob_stream(attachment.blob, disposition: 'inline')
      end
    end

    private

    # Devise answers a missing login with `throw :warden`. The catch for it sits in a
    # middleware of the request thread, and this action runs in a thread of its own
    # (ActionController::Live, through ActiveStorage::Streaming): there the throw arrives
    # nowhere, and until 2026-09-30 every request without a login ended as a 500 instead
    # of at the login. No file was ever sent, the request failed closed; but an expired
    # session looked like a server error, to the reader and in the error log.
    #
    # Caught here, in the thread that throws. A timed-out session throws the same way,
    # from inside Devise, and lands here too.
    def authenticate_user!(*)
      signed_in = false
      catch(:warden) do
        super
        signed_in = true
      end
      redirect_to new_user_session_path unless signed_in
    end

    # For a kind that names a version: says so to the browser, and answers 304 (true)
    # when the browser already holds it.
    def fresh_version?(config, record)
      version = config[:version]&.call(record)
      return false if version.blank?

      expires_in VERSIONED_MAX_AGE, public: false
      !stale?(etag: version, public: false)
    end

    def not_found
      head :not_found
    end
  end
end

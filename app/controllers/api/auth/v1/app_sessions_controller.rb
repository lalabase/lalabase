# frozen_string_literal: true

module Api
  module Auth
    module V1
      # POST /api/auth/v1/app_sessions: e-mail address, password and a device
      # name for an access token of kind app_session. The token is in this one
      # answer and nowhere else, so the door takes no Idempotency-Key: the store
      # behind that header keeps answers, and this one must not be kept. A client
      # that lost the answer signs in again.
      #
      # This controller shapes the call and the answer. Who may sign in is
      # AppSessions::Authentication, the write is Actors::CreateAppSession.
      #
      # It never tells more than the web sign-in: an unknown address, a wrong
      # password and a locked account read the same (status, body, language).
      class AppSessionsController < BaseController
        JSON_MEDIA_TYPE = 'application/json'
        DEVICE_NAME_MAX = 255

        # reason => status, the legacy `error` value and Devise's own sentence.
        REFUSALS = {
          invalid_credentials: { status: :unauthorized, error: 'unauthorized', message: 'devise.failure.invalid' },
          email_unconfirmed: { status: :forbidden, error: 'forbidden', message: 'devise.failure.unconfirmed' },
          account_deactivated: { status: :forbidden, error: 'forbidden', message: 'devise.failure.account_deactivated' }
        }.freeze

        # `login` is the address as typed, before anybody is looked up.
        Input = Data.define(:login, :password, :device_name, :errors)

        # The per-address brake reads the address from a JSON body of at most
        # Lalabase::AuthBodyLimit::MAX_BODY_BYTES. Anything else would be an
        # attempt the brake cannot count, so it is no attempt.
        before_action :require_json
        before_action :refuse_oversized_body

        def create
          input = read_input
          return render_error(error: 'validation_failed', errors: input.errors, status: :unprocessable_content) if input.errors.any?

          attempt = AppSessions::Authentication.call(email: input.login, password: input.password, request: request)
          return refuse(attempt.failure) unless attempt.success?

          result = Actors::CreateAppSession.call(current_user: attempt.user, device_name: input.device_name,
                                                 request: request)
          return render_error(error: 'internal_error', status: :internal_server_error) unless result.success?

          render json: { data: created_payload(result.resource, attempt.user) }, status: :created
        end

        private

        def require_json
          return if request.media_type == JSON_MEDIA_TYPE

          render_error(error: 'unsupported_media_type', code: 'invalid_input', status: :unsupported_media_type,
                       message: I18n.t('services.app_sessions.unsupported_media_type'))
        end

        # Lalabase::AuthBodyLimit refuses what Content-Length admits to. A body
        # sent without a length (chunked) passes it, so the size is measured here
        # once more, before anybody is looked up.
        def refuse_oversized_body
          return unless request.raw_post.to_s.bytesize > Lalabase::AuthBodyLimit::MAX_BODY_BYTES

          render_error(error: 'body_too_large', code: 'invalid_input', status: :content_too_large)
        end

        # Reads the body and nothing else (no query string), each field as text
        # or not at all: a list or a hash where a text belongs is a missing field,
        # and so is a text with a NUL byte, which neither the database nor the
        # password hash takes.
        def read_input
          body = request.request_parameters
          login = text_at(body, 'user', 'email')
          password = text_at(body, 'user', 'password')
          device_name = text_at(body, 'device', 'name').to_s.squish
          errors = []
          errors << I18n.t('services.app_sessions.email_missing') if login.blank?
          errors << I18n.t('services.app_sessions.password_missing') if password.blank?
          errors << I18n.t('services.app_sessions.device_name_blank') if device_name.blank?
          too_long = device_name.length > DEVICE_NAME_MAX
          errors << I18n.t('services.app_sessions.device_name_too_long', count: DEVICE_NAME_MAX) if too_long
          Input.new(login: login, password: password, device_name: device_name, errors: errors)
        end

        def text_at(body, group, field)
          section = body[group]
          value = section[field] if section.is_a?(Hash)
          value if value.is_a?(String) && value.exclude?("\u0000")
        end

        def refuse(reason)
          refusal = REFUSALS.fetch(reason)
          render_error(error: refusal[:error], status: refusal[:status], reason: reason.to_s,
                       message: I18n.t(refusal[:message], authentication_keys: User.human_attribute_name(:email)))
        end

        # current_user is the person who just proved the password: the answer
        # names their own account, to themselves.
        def created_payload(token, current_user)
          {
            token: token.token,
            session: {
              id: token.id,
              kind: token.kind,
              name: token.name,
              prefix: token.token_prefix,
              read_only: token.read_only?,
              all_organisations: token.all_organisations?,
              expires_at: token.expires_at.iso8601,
              ends_at: token.ends_at.iso8601
            },
            user: { id: current_user.id, email: current_user.email, display_name: current_user.display_name }
          }
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module Auth
    # API-only base of the sign-in door of clients (/api/auth/v1): what a program
    # may ask BEFORE it holds a token. Nobody is signed in here, so this base has
    # no token authentication, no Pundit and no tenant. Under /api/v1 a person
    # with a token calls; that base asks for the token, answers in its owner's
    # language and remembers answers per token, and signing in has none of that.
    #
    # Errors have the shape of /api/v1 (Api::V1::ErrorBody): the same client
    # reads both doors and should need one parser.
    #
    # The size limit of a body is NOT here. The body is already parsed by the
    # time a callback runs, so it lives one layer out, in Lalabase::AuthBodyLimit.
    class BaseController < ActionController::API
      # The body is read as sent. A wrapped copy under the controller's name
      # would be a second place for a password.
      wrap_parameters false

      # A body that is not the JSON it claims to be. The request log swallows
      # this error at its first read; it is raised when an action asks for the
      # parameters, after the callbacks below.
      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :unreadable_body

      around_action :in_request_language
      before_action :never_store
      before_action :refuse_in_demo_mode

      private

      # The language of the request: the best supported Accept-Language entry,
      # else the default. NEVER the profile language of an account: the language
      # of a refusal would then tell whether the address has an account.
      def in_request_language(&)
        I18n.with_locale(accept_language_locale || I18n.default_locale, &)
      end

      # The same reading as ApplicationController#browser_locale, written out a
      # second time on purpose: that controller is the base of the pages with a
      # session, and this door shares no ancestor with it.
      def accept_language_locale
        candidates = request.get_header('HTTP_ACCEPT_LANGUAGE').to_s.split(',').filter_map.with_index do |entry, index|
          language_range, *parameters = entry.strip.split(';').map(&:strip)
          quality_parameter = parameters.find { |parameter| parameter.downcase.start_with?('q=') }
          quality = quality_parameter ? Float(quality_parameter.split('=', 2).last, exception: false) : 1.0
          next unless quality&.between?(0.0, 1.0) && quality.positive?

          language = language_range.to_s.downcase.split('-', 2).first.to_s
          [language.to_sym, quality, index] if language.present? && I18n.locale_available?(language)
        end

        candidates.max_by { |_locale, quality, index| [quality, -index] }&.first
      end

      # An answer of this door may carry a token: no cache keeps any of them.
      def never_store
        no_store
      end

      # Every visitor of the public demo shares one account whose password is
      # published, and that account is exempt from the lock and the per-address
      # brake. Without this bar each of them could fetch a writing token for it.
      # 404, as an instance without this door answers. No controller skips this
      # callback; one that still answers there says so in #answers_in_demo?.
      def refuse_in_demo_mode
        return unless Lalabase::Demo.enabled?
        return if answers_in_demo?

        render_error(error: 'not_found', status: :not_found)
      end

      def answers_in_demo?
        false
      end

      # Without the text of the exception: it quotes the body, and a body that
      # failed to parse may hold a password.
      def unreadable_body
        never_store
        return render_error(error: 'not_found', status: :not_found) if Lalabase::Demo.enabled?

        render_error(error: 'bad_request', status: :bad_request)
      end

      # Every error body of this door goes through here (Api::V1::ErrorBody).
      def render_error(error:, status:, code: nil, **extra)
        render json: Api::V1::ErrorBody.build(error: error, code: code, **extra), status: status
      end
    end
  end
end

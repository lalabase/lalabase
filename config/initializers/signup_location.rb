# frozen_string_literal: true

# Where self-registration happens for THIS instance (website split, step W4).
#
# Off unless configured, and that is the point: the core is open source. A
# self-hosted instance has no separate website, so /users/sign_up keeps serving
# its own form, exactly as it does today. Only an operator who runs the public
# pages as a second program points this at them.
#
# The URL is the LANGUAGE-NEUTRAL entry of that program, not one of its
# localised pages: which language a visitor gets is a decision of the program
# that owns those addresses, and encoding "German is /registrieren, English is
# /sign-up" here would put the website's URL table into the core, which the
# split exists to remove.
module Lalabase
  class SignupLocation
    SCHEMES = %w[https http].freeze

    def self.from_env(env = ENV)
      new(url: env['LALABASE_SIGNUP_URL'])
    end

    def initialize(url: nil)
      @url = usable(url)
      @rejected = url.to_s.strip.present? && @url.nil?
    end

    attr_reader :url

    def elsewhere?
      url.present?
    end

    # A configured value that is not an absolute http(s) URL is ignored rather
    # than redirected to: a relative or javascript: value would turn the public
    # sign-up into someone else's page, and a typo should leave the instance
    # working rather than send people somewhere.
    def rejected_url?
      @rejected
    end

    private

    def usable(value)
      candidate = value.to_s.strip
      return if candidate.blank?

      uri = URI.parse(candidate)
      candidate if SCHEMES.include?(uri.scheme) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end
  end
end

Rails.application.config.x.signup_location = Lalabase::SignupLocation.from_env

if Rails.application.config.x.signup_location.rejected_url?
  Rails.application.config.after_initialize do
    Rails.logger.warn(
      '[signup] Ignoring LALABASE_SIGNUP_URL: it is not an absolute http(s) URL. ' \
      '/users/sign_up keeps serving this instance own form.'
    )
  end
end

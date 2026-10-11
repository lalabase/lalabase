# frozen_string_literal: true

# The shared secret the separate website presents when it creates an account
# through POST /api/provisioning/v1/signups (website split, step W2.3).
# Contract: docs/api/provisioning_v1.md.
#
# Off unless configured. Without a usable secret the endpoint answers 404, so a
# self-hosted instance never carries a door it does not use, and a truncated or
# pasted-wrong value fails loudly instead of guarding account creation with four
# characters.
#
# The website and the core are switched over one after the other, so
# LALABASE_PROVISIONING_SECRET_PREVIOUS keeps the old secret valid during a
# rotation: set the new secret in the core, move the old one to _PREVIOUS,
# switch the website, then drop _PREVIOUS.
module Lalabase
  class ProvisioningConfiguration
    # 32 random bytes as hex. `openssl rand -hex 32` produces exactly this.
    MINIMUM_SECRET_LENGTH = 64

    # A signup is a handful of short fields. Anything larger is a mistake or a
    # probe. Enforced by Lalabase::ProvisioningBodyLimit, which sits in front of
    # the parser; a controller callback runs too late to keep the body unread.
    MAX_BODY_BYTES = 16.kilobytes

    # About the visitor the website acts for, not about the signup itself. Both
    # are believed exactly as far as the caller is: they arrive with a valid
    # secret or not at all.
    VISITOR_IP_HEADER = 'X-Lalabase-Visitor-IP'
    VISITOR_USER_AGENT_HEADER = 'X-Lalabase-Visitor-User-Agent'

    def self.from_env(env = ENV)
      new(secret: env['LALABASE_PROVISIONING_SECRET'],
          previous_secret: env['LALABASE_PROVISIONING_SECRET_PREVIOUS'])
    end

    def initialize(secret: nil, previous_secret: nil)
      @secret = usable(secret)
      @previous_secret = usable(previous_secret)
      @rejected = [secret, previous_secret].any? { |value| value.to_s.strip.present? && usable(value).nil? }
    end

    # A lone _PREVIOUS does not open the door: a rotation that lost its current
    # secret is a configuration error, not a half-open endpoint.
    def enabled?
      @secret.present?
    end

    def authenticated?(candidate)
      return false unless enabled?

      accepted_secrets.any? { |secret| secure_equal?(secret, candidate.to_s) }
    end

    # True when a value was configured but could not be used. The boot warning
    # below says so once, because the symptom (404) looks exactly like "not
    # configured at all".
    def rejected_secret?
      @rejected
    end

    private

    def accepted_secrets
      [@secret, @previous_secret].compact
    end

    def usable(value)
      candidate = value.to_s.strip
      candidate if candidate.length >= MINIMUM_SECRET_LENGTH
    end

    # Digests first: secure_compare needs equal lengths, and the length of our
    # secret is not something a caller should be able to measure.
    def secure_equal?(left, right)
      return false if left.blank? || right.blank?

      ActiveSupport::SecurityUtils.secure_compare(
        OpenSSL::Digest::SHA256.hexdigest(left),
        OpenSSL::Digest::SHA256.hexdigest(right)
      )
    end
  end
end

Rails.application.config.x.provisioning = Lalabase::ProvisioningConfiguration.from_env

# In FRONT of Rack::MethodOverride, which reads the form body of every POST to
# look for _method: measured, a 17 KB form body was already parsed
# (rack.request.form_hash in env) by the time a check further down the stack
# ran. Behind ActionDispatch::Executor, so the rejection still runs inside the
# executor context.
require 'lalabase/provisioning_body_limit'
Rails.application.config.middleware.insert_before(
  Rack::MethodOverride, Lalabase::ProvisioningBodyLimit,
  limit: Lalabase::ProvisioningConfiguration::MAX_BODY_BYTES
)

if Rails.application.config.x.provisioning.rejected_secret?
  Rails.application.config.after_initialize do
    Rails.logger.warn(
      '[provisioning] Ignoring a configured secret shorter than ' \
      "#{Lalabase::ProvisioningConfiguration::MINIMUM_SECRET_LENGTH} characters. " \
      'POST /api/provisioning/v1/signups stays closed until it is replaced.'
    )
  end
end

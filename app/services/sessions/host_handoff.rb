# frozen_string_literal: true

# The login hand-off between hosts (doc/org_subdomains_plan.md, S3). Each host keeps a
# session of its own (host-only cookie); a person signs in on the main host only, and this
# carries the session to one organisation host:
#
#   1. the organisation host puts a random state value into a cookie of its own and sends
#      its digest to the main host (Sessions::HandoffStartsController);
#   2. the main host, signed in, mints a token for that user, that host, that path and
#      that state digest (Sessions::HandoffsController);
#   3. the organisation host claims the token with the state from its cookie
#      (Sessions::ClaimsController) and signs the user in.
#
# The binding to the browser is the state: a claim address opened in another browser (sent
# by somebody to sign a victim into the sender's account, or read from a log) finds no
# matching cookie and is refused. The token is single use, valid VALID_FOR, stored as a
# digest, and burnt by any claim, a failed one included.
#
# The sibling Signups::Handoff signs in a visitor the website just signed up; it is good
# once per account and binds nothing to a host or a browser, so it is not reused here.
#
# Entry point: mint and claim.
module Sessions
  class HostHandoff
    VALID_FOR = 60.seconds
    # The state cookie lives only for the round trip through the main host (and a sign-in
    # there, if needed).
    STATE_VALID_FOR = 10.minutes
    MAX_PATH_LENGTH = 2000
    DIGEST_FORMAT = /\A\h{64}\z/

    def self.digest(value)
      OpenSSL::Digest::SHA256.hexdigest(value.to_s)
    end

    def self.new_secret
      SecureRandom.urlsafe_base64(32)
    end

    # A path on the same host, never a URL: starts with exactly one slash, no backslash,
    # no control characters. Anything else becomes "/".
    def self.safe_path(path)
      path = path.to_s
      return '/' unless path.start_with?('/')
      return '/' if path.start_with?('//') || path.include?('\\')
      return '/' if path.length > MAX_PATH_LENGTH || path.match?(/[[:cntrl:]]/)

      path
    end

    # The cookie that carries the state, per environment. With TLS it carries the
    # __Host- prefix, so a sibling host below the same domain cannot plant one.
    def self.state_cookie_name
      base = "lalabase_#{Rails.env}_handoff_state"
      Rails.application.config.force_ssl ? "__Host-#{base}" : "_#{base}"
    end

    # @return [String] the token for the claim address
    def self.mint(user:, host:, path:, state_digest:)
      raise ArgumentError, 'state digest' unless state_digest.to_s.match?(DIGEST_FORMAT)

      token = new_secret
      SessionHandoff.where(expires_at: ...1.hour.ago).delete_all
      SessionHandoff.create!(user: user, token_digest: digest(token), state_digest: state_digest,
                             host: host, path: safe_path(path), expires_at: VALID_FOR.from_now)
      token
    end

    Claim = Data.define(:user, :path)

    # @return [Claim, nil] the user and the path when this call consumed a valid token for
    #   this host and this browser's state; nil in every other case, and the token is gone.
    def self.claim(token:, host:, state:)
      return nil if token.blank? || state.blank?

      row = SessionHandoff.transaction do
        found = SessionHandoff.lock.find_by(token_digest: digest(token))
        found&.delete
        found
      end
      return nil unless row
      return nil unless row.expires_at.future?
      return nil unless row.host == host.to_s.downcase
      return nil unless ActiveSupport::SecurityUtils.secure_compare(row.state_digest, digest(state))

      user = row.user
      return nil unless user&.active_for_authentication?

      Claim.new(user: user, path: row.path)
    end
  end
end

# frozen_string_literal: true

# What the activity log notes about the request of a client sign-in or sign-out,
# read once and made safe to store. It stands in for the request where
# UserActivity.track! reads it (remote_ip, user_agent, session).
#
# The log notes an attempt on a known account and on nobody else. So a header
# that makes the note raise becomes an answer only a known address gives, and a
# caller chooses its headers:
#
# * A User-Agent of bytes that are no UTF-8, or with a NUL byte, is refused by
#   the database. It is scrubbed here, and cut to what a row should hold.
# * A Client-IP that contradicts X-Forwarded-For makes Rails refuse to name the
#   address at all (ActionDispatch::RemoteIp::IpSpoofAttackError). The note then
#   takes the address the brake counts by (Rack's reading), if it is one: Rack
#   hands on the last forwarded entry as it came, a host name or six thousand
#   characters, and the column has an index a long value does not fit.
#
# Entry point: .wrap
module AppSessions
  class RequestFacts
    USER_AGENT_MAX = 255

    # @param request [ActionDispatch::Request, RequestFacts, nil]
    # @return [RequestFacts, nil] nil stays nil: no request, nothing to note
    def self.wrap(request)
      return request if request.nil? || request.is_a?(self)

      new(request: request)
    end

    def initialize(request:)
      @request = request
    end

    def remote_ip
      @request.remote_ip
    rescue ActionDispatch::RemoteIp::IpSpoofAttackError
      address_or_nil(@request.ip)
    end

    def user_agent
      text = @request.user_agent.to_s.dup.force_encoding(Encoding::UTF_8).scrub('').delete("\u0000")
      text.first(USER_AGENT_MAX).presence
    end

    # The door has no session of its own; a caller that sends the cookie of a web
    # session is read as the web reads it.
    delegate :session, to: :@request

    private

    def address_or_nil(text)
      IPAddr.new(text.to_s).to_s
    rescue IPAddr::Error
      nil
    end
  end
end

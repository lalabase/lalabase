# frozen_string_literal: true

# Rate limiting and brute-force protection
class Rack::Attack
  # ===========================================================================
  # PATH MATCHERS — format-tolerant on purpose
  # ===========================================================================
  # Every Rails route ends in an optional (.:format) segment and req.path KEEPS
  # that suffix. `req.path == '/users/sign_in'` is therefore FALSE for
  # "/users/sign_in.json" — a request that still resolves to
  # users/sessions#create and is processed normally. A discriminator returning
  # nil makes Rack::Attack skip the throttle ENTIRELY, so four characters used
  # to disable the limit (measured before the fix: six POSTs to
  # /users/sign_in.json all answered 401, never 429 — unlimited credential
  # stuffing).
  #
  # Same defect class as the detect_participants bypass (#244), which used
  # end_with?. NEITHER == NOR end_with? IS SAFE. Only a prefix match is immune,
  # which is why the /api/ and /webhooks/ throttles further down keep their
  # start_with?. Everything else matches through a constant built from this
  # fragment — pinned by spec/requests/auth_throttle_spec.rb.
  #
  # Trailing and repeated slashes are handled by matching against
  # normalized_path (below), NOT here: the Rails router also resolves POST
  # /users/, POST //users and POST /users// to registrations#create, and
  # req.path keeps every one of those forms verbatim. A `/?` in this suffix only
  # covered ONE of them; the normalizer covers all of them and every anchored
  # matcher routes through it, so this fragment only has to close the .json hole.
  FORMAT_SUFFIX = '(\.[^/]+)?'

  SIGN_IN_PATH = %r{\A/users/sign_in#{FORMAT_SUFFIX}\z}
  ADMIN_LOG_IN_PATH = %r{\A/admin/log_in#{FORMAT_SUFFIX}\z}
  PASSWORD_PATH = %r{\A/users/password#{FORMAT_SUFFIX}\z}
  REGISTRATION_PATH = %r{\A/users#{FORMAT_SUFFIX}\z}
  PROVISIONING_SIGNUPS_PATH = %r{\A/api/provisioning/v1/signups#{FORMAT_SUFFIX}\z}
  SIGNUP_HANDOFF_PATH = %r{\A/users/signup_handoff#{FORMAT_SUFFIX}\z}
  CONFIRMATION_PATH = %r{\A/users/confirmation#{FORMAT_SUFFIX}\z}
  DATA_EXPORT_PATH = %r{\A/user_data_export#{FORMAT_SUFFIX}\z}
  MCP_PATH = %r{\A/api/mcp#{FORMAT_SUFFIX}\z}
  DETECT_PARTICIPANTS_PATH = %r{/meetings/detect_participants#{FORMAT_SUFFIX}\z}
  DIRECT_UPLOADS_PATH = %r{\A/rails/active_storage/direct_uploads#{FORMAT_SUFFIX}\z}
  # The byte channel of a direct upload: PUT with the signed token from the POST above.
  DISK_UPLOADS_PATH = %r{\A/rails/active_storage/disk/[^/]+\z}

  # Signup allowance per IP. Deliberately generous: a whole invited team can sit
  # behind one office NAT and accept their invitations within the hour (the
  # token path posts here too), and locking that out would be worse than the
  # abuse it prevents. Still cuts the ceiling from the global 300/5min (~3600/h)
  # to 20/h — and since the onboarding seed (S1) every signup writes user +
  # organisation + role + membership + tutorial project with tickets and
  # notifications, that flood is expensive.
  REGISTRATIONS_LIMIT = 20
  REGISTRATIONS_PERIOD = 1.hour

  # Per-IP is the wrong unit against a botnet: whoever rotates addresses inside
  # one provider block never reaches 20 anywhere. The /24 (IPv6: /64) is the
  # smallest unit an attacker cannot leave for free. Higher than the per-IP
  # limit because a whole office building can legitimately sit in one /24.
  REGISTRATIONS_SUBNET_LIMIT = 40
  REGISTRATIONS_SUBNET_PERIOD = 1.hour

  # IPv6 only, one step coarser: a /48-/56 belongs to a single subscriber, so the
  # /64 bucket alone lets one IPv6 customer walk thousands of free /64s. Higher
  # than the /24 limit because a /48 can hold a genuinely large org; low enough
  # that ten thousand registrations/hour from one subscriber cannot hide in it.
  REGISTRATIONS_SUBNET_V6_LIMIT = 100

  # DELIBERATELY A TRACK, NOT A THROTTLE. A global registration cap would let
  # anyone shut the front door for real customers by burning the bucket -- the
  # attacker's requests count too, and the bot trap runs LATER in the stack, so
  # even rejected junk would fill it. This only raises a log line when the
  # instance-wide rate leaves the normal range, which is the thing we actually
  # lacked: noticing a wave at all.
  REGISTRATIONS_GLOBAL_ALERT_LIMIT = 40
  REGISTRATIONS_GLOBAL_ALERT_PERIOD = 1.hour

  # Confirmation resend mails an ARBITRARY address on request — without a limit
  # it is an open relay for harassment and the fastest way to burn the sender
  # reputation. Mirrors the password-reset limit, which has the same property.
  CONFIRMATIONS_LIMIT = 3
  CONFIRMATIONS_PERIOD = 60.seconds

  ### Throttle login attempts per IP ###
  throttle('logins/ip', limit: 5, period: 60.seconds) do |req|
    req.ip if post_to?(req, SIGN_IN_PATH)
  end

  ### Throttle login attempts per email ###
  throttle('logins/email', limit: 5, period: 60.seconds) do |req|
    login_email(req) if post_to?(req, SIGN_IN_PATH)
  end

  ### Throttle the one-time signup link per IP ###
  # A signature nobody can forge is not a reason to answer an endless stream of
  # guesses: this one opens sessions, and the honest visitor follows the link once.
  throttle('signup_handoff/ip', limit: 10, period: 60.seconds) do |req|
    req.ip if get_or_head_to?(req, SIGNUP_HANDOFF_PATH)
  end

  ### Throttle admin login per IP ###
  throttle('admin_logins/ip', limit: 5, period: 60.seconds) do |req|
    req.ip if post_to?(req, ADMIN_LOG_IN_PATH)
  end

  ### Throttle admin login per email ###
  # Mirrors 'logins/email' for the app login. IP-only throttling leaves
  # distributed credential stuffing against a single known admin email
  # (one attempt per rotating IP) unbounded -- and this is the most
  # privileged login in the app. Admin login posts a top-level `email`
  # param (Admin::SessionsController reads params[:email]), NOT user[email].
  throttle('admin_logins/email', limit: 5, period: 60.seconds) do |req|
    req.params['email']&.downcase&.strip if post_to?(req, ADMIN_LOG_IN_PATH)
  end

  ### Throttle password reset per IP ###
  throttle('password_resets/ip', limit: 3, period: 60.seconds) do |req|
    req.ip if post_to?(req, PASSWORD_PATH)
  end

  ### Throttle self-registration per IP ###
  # POST /users had no throttle at all before the registration hardening; only
  # the global requests/ip caught it, three orders of magnitude too high.
  throttle('registrations/ip', limit: REGISTRATIONS_LIMIT, period: REGISTRATIONS_PERIOD) do |req|
    req.ip if post_to?(req, REGISTRATION_PATH)
  end

  ### Throttle self-registration per /24 subnet ###
  # Same request, coarser unit. See REGISTRATIONS_SUBNET_LIMIT above.
  throttle('registrations/subnet', limit: REGISTRATIONS_SUBNET_LIMIT,
                                   period: REGISTRATIONS_SUBNET_PERIOD) do |req|
    subnet_of(req.ip) if post_to?(req, REGISTRATION_PATH)
  end

  ### Throttle self-registration per IPv6 /48 ###
  # The /64 above is what a provider hands ONE customer's device, but providers
  # routinely delegate a whole /48-/56 to a single subscriber, so one IPv6 client
  # legitimately holds 256-65536 distinct /64s and could clear the /64 throttle
  # tens of thousands of times per hour. This coarser /48 bucket bounds that;
  # IPv4 returns nil here (already covered by the /24) so the rule skips it.
  throttle('registrations/subnet_v6', limit: REGISTRATIONS_SUBNET_V6_LIMIT,
                                      period: REGISTRATIONS_SUBNET_PERIOD) do |req|
    subnet_v6_of(req.ip) if post_to?(req, REGISTRATION_PATH)
  end

  ### Watch the instance-wide registration rate (alarm only, never blocks) ###
  track('registrations/global', limit: REGISTRATIONS_GLOBAL_ALERT_LIMIT,
                                period: REGISTRATIONS_GLOBAL_ALERT_PERIOD) do |req|
    'all' if post_to?(req, REGISTRATION_PATH)
  end

  ### Throttle website signups by the visitor the website acts for ###
  # Same budgets as the form above: the funnel is the same funnel, only the
  # program in front of it changed.
  throttle('provisioning_signups/ip', limit: REGISTRATIONS_LIMIT,
                                      period: REGISTRATIONS_PERIOD) do |req|
    provisioning_throttle_ip(req) if post_to?(req, PROVISIONING_SIGNUPS_PATH)
  end

  throttle('provisioning_signups/subnet', limit: REGISTRATIONS_SUBNET_LIMIT,
                                          period: REGISTRATIONS_SUBNET_PERIOD) do |req|
    subnet_of(provisioning_throttle_ip(req)) if post_to?(req, PROVISIONING_SIGNUPS_PATH)
  end

  throttle('provisioning_signups/subnet_v6', limit: REGISTRATIONS_SUBNET_V6_LIMIT,
                                             period: REGISTRATIONS_SUBNET_PERIOD) do |req|
    subnet_v6_of(provisioning_throttle_ip(req)) if post_to?(req, PROVISIONING_SIGNUPS_PATH)
  end

  track('provisioning_signups/global', limit: REGISTRATIONS_GLOBAL_ALERT_LIMIT,
                                       period: REGISTRATIONS_GLOBAL_ALERT_PERIOD) do |req|
    'all' if post_to?(req, PROVISIONING_SIGNUPS_PATH)
  end

  ### Throttle confirmation resend per IP ###
  throttle('confirmations/ip', limit: CONFIRMATIONS_LIMIT, period: CONFIRMATIONS_PERIOD) do |req|
    req.ip if post_to?(req, CONFIRMATION_PATH)
  end

  ### Throttle GDPR data export requests per IP ###
  # Belt-and-braces: the real throttle is the per-user 24h guard + partial
  # unique index on user_data_exports; this only bounds endpoint abuse per IP.
  throttle('data_exports/ip', limit: 5, period: 1.hour) do |req|
    req.ip if post_to?(req, DATA_EXPORT_PATH)
  end

  ### Throttle webhook endpoints per IP ###
  throttle('webhooks/ip', limit: 30, period: 60.seconds) do |req|
    req.ip if normalized_path(req).start_with?('/webhooks/')
  end

  ### Throttle API requests per IP ###
  throttle('api/ip', limit: 60, period: 60.seconds) do |req|
    next unless normalized_path(req).start_with?('/api/')
    # An authenticated website call is already counted per visitor above. Left
    # in here as well, 60 signups an hour would close the funnel for everyone.
    next if post_to?(req, PROVISIONING_SIGNUPS_PATH) && provisioning_visitor_ip(req)

    req.ip
  end

  ### Throttle API v1 per token (60 req/min) ###
  # Protects against LLM infinite loops + brute force against leaked tokens.
  throttle('api_v1/token', limit: 60, period: 60.seconds) do |req|
    next unless normalized_path(req).start_with?('/api/v1/')

    raw = req.env['HTTP_AUTHORIZATION'].to_s.sub(/\ABearer /, '')
    raw.presence
  end

  ### Throttle MCP endpoint per token (60 req/min) ###
  # D8: an MCP client (LLM agent) drives tools/call directly — no server-side loop
  # cap — so a per-token throttle bounds runaway agents + leaked-token brute force.
  # Per-IP is already covered by the 'api/ip' throttle above (/api/ prefix).
  throttle('api_mcp/token', limit: 60, period: 60.seconds) do |req|
    next unless normalized_path(req).match?(MCP_PATH)

    raw = req.env['HTTP_AUTHORIZATION'].to_s.sub(/\ABearer /, '')
    raw.presence
  end

  ### Throttle meetings AI participant detection per user ###
  # Gespräche Slice 5 (Eng-Review D5): unpersisted, repeatable LLM endpoint —
  # bound per user so a single account cannot burn the org's AI quota by
  # hammering detection. Warden::Manager runs BEFORE Rack::Attack in the
  # middleware stack, so the authenticated user is available here; IP is the
  # fallback for the unauthenticated edge.
  #
  # Matched format-tolerantly like every other path here (DETECT_PARTICIPANTS_PATH
  # at the top of this file) — this endpoint is where the bypass class was first
  # found (#244).
  throttle('meetings/detect_participants/user', limit: 10, period: 60.seconds) do |req|
    req.env['warden']&.user&.id || req.ip if post_to?(req, DETECT_PARTICIPANTS_PATH)
  end

  ### Throttle direct uploads per user ###
  # Each blob created here is disk space; DirectUploadsGuard already turns strangers
  # away with 401, so the unit is the signed-in user, with IP as the fallback for the
  # unauthenticated edge. Generous enough for someone pasting screenshots into a text
  # (one request per image), far below what fills a disk in an afternoon.
  throttle('direct_uploads/user', limit: 60, period: 60.seconds) do |req|
    req.env['warden']&.user&.id || req.ip if post_to?(req, DIRECT_UPLOADS_PATH)
  end

  ### Throttle the byte channel of direct uploads per IP ###
  # The POST above only mints a token; the bytes arrive with PUT /rails/active_storage/
  # disk/:token, signed, without a session, so the user throttle cannot see them and a
  # token holder may upload from any address. One PUT per file, so the same 60 per
  # minute as the token side; per IP because that is all this request carries. A
  # per-user byte budget would need a blob-to-user link the schema does not have
  # (doc/inline_bilder_spike_plan.md, Abschnitt 3, Restluecke).
  throttle('disk_uploads/ip', limit: 60, period: 60.seconds) do |req|
    req.ip if put_to?(req, DISK_UPLOADS_PATH)
  end

  ### General throttling per IP (all requests) ###
  throttle('requests/ip', limit: 300, period: 5.minutes) do |req|
    req.ip unless normalized_path(req).start_with?('/assets')
  end

  # req.path verbatim, with repeated and trailing slashes squeezed out, so the
  # anchored matchers above cannot be skipped by a client that pads the path.
  # //users, /users// and /users/ all resolve to registrations#create, and
  # req.path keeps the padding, so a raw `req.path.match?` misses every one of
  # them -- the same bypass class the .json hole opened, one directory level up
  # (measured against the booted router). normalize_path also guarantees a
  # leading slash and keeps the .:format suffix, which FORMAT_SUFFIX still eats.
  #
  # Memoised in the Rack env: ~14 discriminator blocks call this on every request
  # (including every /assets/* request the requests/ip block evaluates), and
  # normalize_path allocates a fresh string and runs several passes each time.
  # One computation per request instead of fourteen.
  #
  # NOTE the bare-prefix edge: normalize_path drops the trailing slash, so the
  # literal paths /webhooks/, /api/ and /api/v1/ normalise to /webhooks, /api,
  # /api/v1 and no longer match the start_with?('/webhooks/') prefix rules. Those
  # bare paths route nowhere (404), and every real sub-path (/api/v1/x) is
  # unaffected, so this is an accepted, harmless narrowing rather than a hole.
  def self.normalized_path(req)
    req.env['rack.attack.normalized_path'] ||=
      ActionDispatch::Journey::Router::Utils.normalize_path(req.path)
  end

  # One owner for the "POST to this anchored path" test that every throttle below
  # repeats. Without it each new throttle re-inlines `normalized_path(req).match?`
  # by hand and the next one can silently fall back to raw req.path, reopening the
  # padding bypass the normalizer closes (CLAUDE.md: duplicated enforcement).
  def self.post_to?(req, pattern)
    req.post? && normalized_path(req).match?(pattern)
  end

  # The address a login attempt names, from a form OR a JSON body. req.params
  # holds only form and query parameters, so a JSON login (Devise parses it
  # later, in the controller) used to reach no per-email bucket at all: a
  # distributed guess at ONE address walked past the brake that exists for it.
  # Reads at most LOGIN_BODY_LIMIT bytes and rewinds, so the app still sees the
  # whole body; anything unparseable counts as no address (the IP rule stays).
  LOGIN_BODY_LIMIT = 4.kilobytes

  def self.login_email(req)
    email = req.params.dig('user', 'email')
    email ||= json_login_email(req) if req.media_type == 'application/json'
    email.is_a?(String) ? email.downcase.strip : nil
  end

  def self.json_login_email(req)
    body = req.body.read(LOGIN_BODY_LIMIT)
    req.body.rewind
    JSON.parse(body.to_s).dig('user', 'email')
  rescue JSON::ParserError, TypeError, NoMethodError
    nil
  end

  def self.put_to?(req, pattern)
    req.put? && normalized_path(req).match?(pattern)
  end

  # HEAD too: Rails runs a GET action for a HEAD request, so a rule that counts
  # only GET leaves the same work reachable without a limit.
  def self.get_or_head_to?(req, pattern)
    (req.get? || req.head?) && normalized_path(req).match?(pattern)
  end

  # The website calls from one address, so a per-IP bucket would lump every
  # visitor of the public pages into one. An authenticated call may therefore
  # name the visitor it acts for. Without a valid secret the claim is ignored
  # and the caller's own address counts, so nobody can pick a bucket before the
  # controller has checked anything.
  def self.provisioning_visitor_ip(req)
    authorization = req.get_header('HTTP_AUTHORIZATION').to_s
    return unless authorization.start_with?('Bearer ')
    return unless Rails.application.config.x.provisioning.authenticated?(authorization.delete_prefix('Bearer '))

    IPAddr.new(req.get_header('HTTP_X_LALABASE_VISITOR_IP').to_s).to_s
  rescue ArgumentError
    nil
  end

  def self.provisioning_throttle_ip(req)
    provisioning_visitor_ip(req) || req.ip
  end

  # Network part of an address: the first three octets for IPv4, the first four
  # groups (the /64, what a provider hands a single customer) for IPv6. Returns
  # nil for anything unparseable, which makes Rack::Attack skip the rule rather
  # than throttle a bucket called "".
  def self.subnet_of(ip)
    address = IPAddr.new(ip.to_s)
    # IPv4-mapped IPv6 (::ffff:a.b.c.d) answers ipv6? with true, but its first
    # 64 bits are zero for EVERY such address -- without unwrapping, all mapped
    # clients share the single bucket "::" and 40 requests from one attacker
    # would close registration for the lot of them.
    address = address.native if address.ipv6? && address.ipv4_mapped?
    (address.ipv6? ? address.mask(64) : address.mask(24)).to_s
  rescue ArgumentError
    # IPAddr::InvalidAddressError is an ArgumentError; catching the parent alone
    # also covers a mask that cannot be applied.
    nil
  end

  # The /48 of an IPv6 address, for the coarser second registration bucket.
  # Returns nil for IPv4 (bounded by the /24 already) and for the ipv4-mapped
  # form (unwrapped, then IPv4), so those addresses skip this rule entirely.
  def self.subnet_v6_of(ip)
    address = IPAddr.new(ip.to_s)
    address = address.native if address.ipv6? && address.ipv4_mapped?
    return nil unless address.ipv6?

    address.mask(48).to_s
  rescue ArgumentError
    nil
  end

  ### Response on rate limit ###
  self.throttled_responder = lambda do |req|
    match_data = req.env['rack.attack.match_data']
    now = match_data[:epoch_time]

    headers = {
      'RateLimit-Limit' => match_data[:limit].to_s,
      'RateLimit-Remaining' => '0',
      'RateLimit-Reset' => (now + (match_data[:period] - now % match_data[:period])).to_s,
      'Content-Type' => 'text/plain'
    }

    # Bilingual on purpose: Rack::Attack runs in front of the locale middleware,
    # so there is no reliable request locale here, and the app serves an English
    # audience too. A single German line would be the only untranslated response
    # a throttled visitor ever sees.
    [429, headers, ["Zu viele Anfragen. Bitte versuchen Sie es später erneut. / Too many requests. Please try again later.\n"]]
  end
end

# ⚠ CLIENT-SPOOFABLE THROTTLE KEY -- needs a server-side fix, NOT a code-only one.
#
# Every `req.ip` above is client-controlled as things stand. req.ip (Rack 3)
# prefers the RFC 7239 Forwarded header; ActionDispatch remote_ip prefers
# X-Forwarded-For. With `config.action_dispatch.trusted_proxies` unset (it is
# nil here) BOTH follow the header the client sent -- measured: a forged
# X-Forwarded-For makes remote_ip return the forged value, so swapping req.ip
# for remote_ip buys nothing. A client can therefore pick a fresh bucket per
# request for registrations/ip and registrations/subnet, and can even spend a
# victim /24's registration budget on purpose. The bot-trap log line has the
# same weakness.
#
# The fix lives at the trust boundary and needs the production topology (Puma
# behind nginx over a unix socket), which is not in this repo, so it is
# deliberately NOT guessed here:
#   1. nginx: set (do not append) X-Forwarded-For to $remote_addr and clear any
#      inbound Forwarded header, so a spoofed value never reaches Rails;
#   2. Rails: set config.action_dispatch.trusted_proxies to the proxy address so
#      remote_ip stops at the nginx hop and returns the real client.
# Until both are in place the per-IP and subnet throttles bound accidental
# floods (a real botnet without header spoofing) but not a deliberate one; the
# path-normalisation and honeypot defences above do not depend on the client IP.

# Every limit above was invisible in the log: a throttled request answers 429
# and disappears, and a track answers nothing at all. Without these two lines a
# wave is only discoverable afterwards, in the database.
%w[throttle track].each do |event_type|
  ActiveSupport::Notifications.subscribe("#{event_type}.rack_attack") do |_name, _start, _finish, _id, payload|
    request = payload[:request]
    # .inspect the path: PATH_INFO arrives URL-decoded, so a request path
    # containing %0A would otherwise inject attacker-chosen newlines into this
    # log -- forged "[RackAttack] throttle ..." lines that poison the exact
    # wave-detection signal these subscribers exist to provide. requests/ip
    # matches every path, so this is reachable.
    Rails.logger.warn(
      "[RackAttack] #{event_type} rule=#{request.env['rack.attack.matched']} " \
      "ip=#{request.ip} path=#{request.path.inspect}"
    )
  end
end

# frozen_string_literal: true

# The limit on how often one client address may be told that an email address
# already has an account.
#
# The sign-up has to say it. A new account is signed in at once (the grace period
# of the confirmation), an address that is taken never can be, so the two answers
# cannot be made to look alike without sending every newcomer to their mailbox
# first. What the answer must not be is a cheap way to run a list of addresses
# against an instance: with a password too short on purpose the form named both
# errors and wrote nothing, 20 times an hour per client address.
#
# So the answers are counted. After LIMIT of them within PERIOD the sign-up is
# closed to that client address for PERIOD: Rack::Attack asks #banned? in front
# of both doors (the form and the provisioning endpoint) and answers 429. Five,
# because a person meets this answer once or twice (they forgot the account),
# and an office behind one address should not close its own door by accident.
#
# Counted in Rack::Attack's cache and by its Fail2Ban, like every other limit.
# The counter runs in fixed windows of PERIOD, so a patient client gets LIMIT - 1
# answers per window without ever being closed out: this bounds the rate, it
# does not hide the fact. An instance that wants the fact hidden closes
# registration; then no address is looked at before the refusal.
#
# Entry point: record (Actors::CreateSignup, when it answers "taken") and
# banned? (Rack::Attack, before the request reaches a controller).
module Signups
  class TakenAddressBrake
    LIMIT = 5
    PERIOD = 1.day
    BUCKET = 'signup-taken'

    class << self
      # nil or anything that is no address counts nothing: the provisioning
      # endpoint passes nil when the website named no visitor, and counting the
      # website's own address instead would let five visitors close the sign-up
      # for everybody behind it.
      def record(client_ip)
        key = bucket(client_ip)
        return if key.nil?

        Rack::Attack::Fail2Ban.filter(key, maxretry: LIMIT, findtime: PERIOD, bantime: PERIOD) { true }
      end

      def banned?(client_ip)
        key = bucket(client_ip)
        key.present? && Rack::Attack::Fail2Ban.banned?(key)
      end

      private

      # One spelling per address, so the form (the raw address of the request)
      # and the provisioning endpoint (the visitor the website names) meet in
      # the same bucket.
      def bucket(client_ip)
        "#{BUCKET}:#{IPAddr.new(client_ip.to_s)}"
      rescue ArgumentError
        nil
      end
    end
  end
end

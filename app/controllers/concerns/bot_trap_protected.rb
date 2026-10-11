# frozen_string_literal: true

# Bot protection for PUBLIC, unauthenticated forms: a honeypot field plus a
# signed "when was this form rendered" timestamp.
#
# WHY A CONCERN AND NOT A CHECK IN THE CONTROLLER: every sessionless endpoint
# needs the same two checks (sign-up, password reset, confirmation resend, any
# future contact form). Written by hand each time, the rule survives only as
# long as someone remembers it — the next endpoint silently ships without it.
# Including this module, declaring `protect_from_bots only: :create`, and
# rendering `shared/bot_trap_fields` inside the form is the whole contract --
# the include alone wires no before_action.
#
# WHAT IT CATCHES: scripted POSTs that fill every field they find and submit
# instantly. It does NOT stop a headless browser driven at human speed — that is
# a captcha's job and deliberately out of scope (doc/bot_registrierungen_plan.md).
#
# BOTH PARAMS ARE TOP-LEVEL, never nested under the model key. Strong parameters
# never see them, so no sanitizer anywhere needs to know they exist.
#
# ACCEPTED RISK: the signed timestamp is stateless and multi-use. One fetch of
# the form yields a token that, once MINIMUM_FILL_SECONDS old, validates any
# number of POSTs from any IP until MAXIMUM_FORM_AGE. Statelessness is the
# point (caching, multiple tabs, no session); against a bot that harvests a
# token first, the remaining defenses are the honeypot and the Rack::Attack
# throttles. If that ever proves too weak, the next step is signing the client
# IP into the token — at the price of a visible retry for people who switch
# networks mid-form.
#
# ACCEPTED RISK: latency fingerprint on the honeypot pretend-success. The
# response mimics a real signup's status, flash and redirect SHAPE, but returns
# before any bcrypt hashing or DB write, so it answers measurably faster. A bot
# timing responses can still tell trapped from accepted. Closing it would mean
# burning comparable work in the fake branch; not worth it while the honeypot's
# value is catching dumb scripted fills, which do not measure latency.
#
# ACCEPTED RISK: the pretend-success only mimics the immediate response. FOLLOWING
# the redirect distinguishes it — a real grace-period signup lands on a live
# dashboard, the trap's random-UUID organisation path bounces to sign-in — as
# does the absent warden session cookie. Same family as the latency tell: a bot
# that follows redirects and diffs the destination can classify the response, but
# a dumb scripted fill (the honeypot's actual target) does neither.
module BotTrapProtected
  extend ActiveSupport::Concern

  # Semantic-free on purpose. Browsers and password managers autofill `website`,
  # `company`, `address` and `phone` — and treat `confirm` as a confirm-field
  # heuristic — which would spring the trap on real people, the exact failure
  # this protection must not have.
  HONEYPOT_FIELD = :reference_note
  TIMESTAMP_FIELD = :form_rendered_at

  # Below this, nobody typed a name, an address and a password.
  MINIMUM_FILL_SECONDS = 3

  # Above this the signature is treated as stale rather than hostile: a form left
  # open overnight gets a friendly "please try again", not an accusation.
  MAXIMUM_FORM_AGE = 6.hours

  VERIFIER_SALT = 'bot_trap'
  # Shared across every form that includes this concern. Today only the
  # registration includes it, so a single purpose is fine. ⚠ WHEN A SECOND FORM
  # ADOPTS protect_from_bots (password reset, contact, …): a token minted on one
  # form will validate on the other, because salt AND purpose are identical. That
  # lets a bot harvest a timestamp from the cheap form and spend it on the
  # expensive one. Before wiring the second form, scope this per form (e.g.
  # generate/verify with purpose: "#{controller_path}/form_rendered_at") and
  # update bot_trap_request_helpers to match.
  VERIFIER_PURPOSE = :form_rendered_at

  included do
    helper_method :bot_trap_timestamp
  end

  class_methods do
    # Declarative wiring so a controller reads as "this form is protected".
    def protect_from_bots(**options)
      before_action :verify_bot_trap!, **options
    end
  end

  private

  def verify_bot_trap!
    verdict = bot_trap_verdict
    return if verdict == :ok

    log_bot_trap(verdict)

    # Split on purpose (doc/bot_registrierungen_plan.md, decision 1):
    #
    #   honeypot  -> pretend success. A human practically never fills a field
    #                they cannot see, so the false-positive risk is near zero and
    #                the sender gets no signal to tune their script against.
    #   timestamp -> visible rejection. Fast people and autofill are real, and
    #                someone wrongly caught must be able to try again instead of
    #                waiting forever for a mail that was never sent.
    verdict == :honeypot ? bot_trap_pretend_success : bot_trap_reject(verdict)
  end

  # :ok or the reason it failed. Split from the handling for readability and so a
  # future controller (or spec) CAN ask the verdict without triggering a
  # response; today verify_bot_trap! is the only caller.
  def bot_trap_verdict
    return :honeypot if params[HONEYPOT_FIELD].present?

    raw = params[TIMESTAMP_FIELD]
    return :timestamp_missing if raw.blank?

    rendered_at = bot_trap_verifier.verified(raw.to_s, purpose: VERIFIER_PURPOSE)
    return :timestamp_invalid if rendered_at.blank?

    age = Time.current.to_i - rendered_at.to_i

    # Negative age means the signature claims the future — a replayed or
    # hand-built token, caught by the same branch as "too fast".
    return :too_fast if age < MINIMUM_FILL_SECONDS
    return :expired if age > MAXIMUM_FORM_AGE

    :ok
  end

  # Rendered into the form. A fresh value per render, signed so it cannot be
  # back-dated, and stateless so it survives page caching and multiple tabs.
  def bot_trap_timestamp
    bot_trap_verifier.generate(Time.current.to_i, purpose: VERIFIER_PURPOSE)
  end

  def bot_trap_verifier
    Rails.application.message_verifier(VERIFIER_SALT)
  end

  # Overridable: the default is the least surprising thing a public form can do.
  # Controllers that imitate a specific success page (registration mimics
  # Devise's "check your mail") override this.
  def bot_trap_pretend_success
    # 303 like every Rails form responder answers a successful POST; a 302
    # would hand scripts a status-code fingerprint (see the registration
    # override and its mimicry spec).
    # The generic fallback. What a trapped REGISTRATION answers is decided in
    # Users::RegistrationsController, which overrides this so both land on the
    # fresh organisation -- pinned in spec/requests/users/bot_trap_spec.rb,
    # because a different redirect target was once a real fingerprint.
    #
    # Until W6 this said root_path and not main_app.root_path, because the
    # public pages were routed per language and a trapped visitor landing on /
    # instead of /de was itself the tell. Those pages are gone; root_path is /.
    redirect_to root_path, status: :see_other
  end

  def bot_trap_reject(_reason)
    redirect_back fallback_location: root_path,
                  alert: t('flash.bot_trap.rejected')
  end

  # One line per hit, greppable. This is the only place a rejected submission is
  # visible at all — without it the pretend-success branch would be invisible in
  # production and nobody could tell a working trap from a broken one.
  def log_bot_trap(verdict)
    # .inspect the path: it arrives URL-decoded, so a %0A in it would otherwise
    # let a caller inject newlines and forge extra "[BotTrap] blocked ..." log
    # lines, poisoning the one signal that a rejected submission leaves at all.
    Rails.logger.warn(
      "[BotTrap] blocked verdict=#{verdict} path=#{request.path.inspect} ip=#{request.remote_ip}"
    )
  end
end

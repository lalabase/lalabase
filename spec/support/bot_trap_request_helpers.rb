# frozen_string_literal: true

# Public forms carry two extra params (see BotTrapProtected): a honeypot that
# must stay empty and a signed timestamp of the render. A request spec posting
# such a form has to send them, exactly like a browser does — otherwise it tests
# the rejection path by accident.
module BotTrapRequestHelpers
  # Defaults to a form rendered 10 seconds ago: comfortably past
  # MINIMUM_FILL_SECONDS, far inside MAXIMUM_FORM_AGE.
  def bot_trap_params(rendered_seconds_ago: 10)
    { BotTrapProtected::TIMESTAMP_FIELD => bot_trap_timestamp(rendered_seconds_ago) }
  end

  def bot_trap_timestamp(rendered_seconds_ago = 10)
    Rails.application.message_verifier(BotTrapProtected::VERIFIER_SALT)
         .generate(rendered_seconds_ago.seconds.ago.to_i,
                   purpose: BotTrapProtected::VERIFIER_PURPOSE)
  end
end

RSpec.configure do |config|
  config.include BotTrapRequestHelpers, type: :request
end

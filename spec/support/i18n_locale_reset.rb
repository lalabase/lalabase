# frozen_string_literal: true

# Puts I18n.locale back after EVERY example.
#
# I18n.locale is thread state. Since 10.09.2026 ApplicationController#switch_locale sets it
# per request with I18n.with_locale and restores it afterwards, so a request spec no longer
# leaves a language behind. Everything else still can: a view, helper or model spec that
# sets I18n.locale, code that changes it outside a request, an example that stops half-way.
#
# Until 10.09.2026 this comment claimed that in the application "the executor cleans up
# per request". It did not, and the same leak reached real visitors: the sign-up form came
# out in the language of the thread's previous request (spec/requests/locale_per_request_spec.rb).
#
# The bug this hook was written for is order-dependent and therefore expensive: the pricing
# system spec failed only when an English request had run before it. Alone it was green, in
# company red, and the failure showed a completely English page without any hint of who had
# switched it (found on 21.08.2026).
#
# Not `around`: the locale is reset even when the example raises.
RSpec.configure do |config|
  config.after { I18n.locale = I18n.default_locale }
end

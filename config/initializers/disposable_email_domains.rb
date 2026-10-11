# frozen_string_literal: true

# Load and validate the throw-away domain list at boot, so a missing, malformed
# or empty config/disposable_email_domains.yml is discovered on deploy rather
# than on the first sign-up attempt (a lazy load would 500 there) or never (an
# empty list silently disables the filter). DisposableEmailDomains.all logs both
# failure modes; here we only force it to run.
Rails.application.config.after_initialize do
  DisposableEmailDomains.all
end

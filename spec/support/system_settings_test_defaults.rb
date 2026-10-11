# frozen_string_literal: true

# Ensure predictable system settings in test environment
RSpec.configure do |config|
  # Immediate account deletion in tests to match expectations
  config.before(:suite) do
    SystemSetting.set_account_deletion_grace_period_days(0) if defined?(SystemSetting)
  end

  # And again before each example that finds the row gone: the setting is a row,
  # and every truncating spec (system specs, the concurrency specs) wipes it. The
  # deletion specs after them ran with the 30-day default and only scheduled the
  # deletion. Paused, because the lookup must not count as one of the example's
  # own system_settings reads, and running ahead of Prosopite.scan is not enough:
  # a spec that resumes Prosopite in an around hook (auth_throttle_spec) leaves
  # the scan on into the next example.
  config.prepend_before do
    next unless defined?(SystemSetting)

    Prosopite.pause do
      next if SystemSetting.exists?(key: 'account_deletion_grace_period_days')

      SystemSetting.set_account_deletion_grace_period_days(0)
    end
  end
end

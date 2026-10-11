# frozen_string_literal: true

# Enforces the retention promise of the privacy policy, § 4.1: the callback
# number goes once the request is decided, at the latest three months after it
# was made (doc/billing_preisliste_rabatt_plan.md § 12.3.4).
#
# Only the number. Company name and seat stay -- the same company sits in
# accounts.name under the contract, and the applicant remains registered even
# when the request is declined, so deleting the copy would be theatre.
#
# The "at the latest" half is the load-bearing one: a request nobody ever gets
# around to deciding would otherwise keep its number forever, which is exactly
# the failure a retention rule exists to prevent. A promise without a sweeper is
# a sentence, not a mechanism.
class FounderSignupCallbackNumberCleanupJob < ApplicationJob
  queue_as :default

  def perform
    expired = FounderSignup.callback_number_expired
    count = expired.count
    return if count.zero?

    expired.find_each(&:drop_callback_number!)
    Rails.logger.info("[FounderSignup] dropped #{count} callback number(s) past their purpose")
  end
end

# frozen_string_literal: true

# Enforces the retention promise of the privacy policy, § 4.2: where a customer
# came from is deleted twelve months after registration
# (AcquisitionSource::RETENTION, doc/akquise_herkunft.md).
#
# Clears the column, it does not touch the account. The origin is the only part
# of that record with a deadline; name, owner and billing data live under the
# contract and have their own.
#
# update_all deliberately: this runs over rows nobody is editing, needs no
# callbacks, and must not bump updated_at, which the billing views read as
# "somebody changed the account".
class AcquisitionPurgeJob < ApplicationJob
  queue_as :default

  def perform
    count = Account.acquisition_expired.update_all(acquisition: nil)
    return if count.zero?

    Rails.logger.info("[Acquisition] cleared #{count} origin(s) past the #{AcquisitionSource::RETENTION.inspect} retention")
  end
end

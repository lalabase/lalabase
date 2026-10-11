# frozen_string_literal: true

FactoryBot.define do
  # An ok snapshot of an empty account -- the smallest self-consistent row
  # (seat_count must equal the distinct users in pairs, enforced by validation).
  factory :seat_snapshot do
    account
    period_start { Date.current.beginning_of_month }
    status { Subscriptions::Constants::SEAT_SNAPSHOT_STATUS_OK }
    seat_count { 0 }
    pairs { [] }
    computed_at { Time.current }
  end
end

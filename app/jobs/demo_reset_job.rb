# frozen_string_literal: true

# The nightly reset of the public demo (Lalabase::Demo::Reset), scheduled in
# config/recurring.yml at Lalabase::Demo::RESET_HOUR_UTC.
#
# Scheduled on every production instance, and a no-op on all but the demo: without
# both latches (the flag and the marker) it returns before touching anything.
class DemoResetJob < ApplicationJob
  queue_as :default

  def perform
    return unless Lalabase::Demo.resettable?

    world = Lalabase::Demo::Reset.call
    Rails.logger.info("[Demo] reset done, organisation #{world.organisation.id}")
  end
end

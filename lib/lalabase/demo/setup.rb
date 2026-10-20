# frozen_string_literal: true

module Lalabase
  module Demo
    # Turns a fresh instance into the public demo, once: `bin/rails lalabase:demo:setup`.
    #
    # Writes the marker (Demo::MARKER_KEY), the second latch of Lalabase::Demo::Reset,
    # closes the registration, and runs the first reset. Refuses without the flag, and
    # on an instance that has any organisation: whatever is in there would be gone by
    # the next morning.
    class Setup
      class Refused < StandardError; end

      def self.call(**) = new(**).call

      def initialize(now: Time.current)
        @now = now
      end

      # @return [Lalabase::Demo::World]
      def call
        raise Refused, "Set #{ENV_FLAG}=#{ENABLED_VALUE} first." unless Demo.enabled?
        raise Refused, 'This instance is a demo already; it resets every night.' if Demo.marked?
        raise Refused, 'This instance has organisations. A demo resets every night, so it starts empty.' if Organisation.exists?

        SystemSetting.set(:allow_registration, false)
        SystemSetting.set(MARKER_KEY, true)
        Reset.call(now: @now)
      end
    end
  end
end

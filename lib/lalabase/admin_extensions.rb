# frozen_string_literal: true

module Lalabase
  # The named places where the instance admin lets someone else render
  # something (doc/oss_core_split_plan.md 5.2 and 5.6, slice S2).
  #
  # Why this exists: the admin area is split into an open instance admin in the
  # core and a closed operator console that is loaded as an engine, and only in
  # an internal process. Four core pages and the menu carry one operator section
  # each. The core must render those pages with and without the engine, and it
  # must not name an operator route itself. So the page names a slot, and
  # whoever is loaded registers a partial for it. With nothing registered a slot
  # renders nothing, which is exactly the public process.
  #
  # A view renders a slot through `admin_extension_slot` (Admin::ExtensionsHelper).
  #
  # REGISTER INSIDE `config.to_prepare`, never at the top level of an initializer:
  # `lib/` is autoloaded, so in development a code reload replaces this module and
  # an empty registry with it. `to_prepare` runs again after every reload. That is
  # also why `register` is idempotent: in production `to_prepare` runs once, under
  # a test runner that reloads it may run more often.
  #
  # The slot list is a closed constant on purpose. A misspelled slot name would
  # otherwise render nothing, on a page where "nothing" is a legitimate state,
  # and nobody would ever see the section go missing.
  module AdminExtensions
    SLOTS = %i[
      dashboard_management_tiles
      organisation_header
      user_sections
      system_settings_sections
      navigation_management
      navigation_monitoring
    ].freeze

    class UnknownSlot < ArgumentError; end

    @registry = {}
    @mutex = Mutex.new

    class << self
      # partial: the path `render partial:` takes, e.g. 'admin/operator/dashboard/tile'.
      def register(slot, partial:)
        slot = checked(slot)
        @mutex.synchronize do
          current = @registry.fetch(slot, [])
          @registry = @registry.merge(slot => (current + [partial]).freeze) unless current.include?(partial)
        end
        nil
      end

      def partials_for(slot)
        @registry.fetch(checked(slot), [].freeze)
      end

      # Runs the block as the public process sees the admin area: nothing
      # registered. Specs only; the registry is restored afterwards, also when
      # the block raises.
      def with_empty_registry
        previous = @mutex.synchronize do
          saved = @registry
          @registry = {}
          saved
        end
        yield
      ensure
        @mutex.synchronize { @registry = previous }
      end

      private

      def checked(slot)
        return slot if SLOTS.include?(slot)

        raise UnknownSlot, "unknown admin extension slot #{slot.inspect}, known slots: #{SLOTS.join(', ')}"
      end
    end
  end
end

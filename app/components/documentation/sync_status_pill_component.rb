# frozen_string_literal: true

module Documentation
  # Live sync-status badge for a DocumentationSet. Context-free (only `t`), so it
  # can be re-rendered anywhere. Uses success/danger/info tones per the design
  # system (G4) — never lime, which is reserved for the primary action.
  class SyncStatusPillComponent < ViewComponent::Base
    STATUS_STYLES = {
      'never_synced' => 'bg-gray-100 text-gray-700 border-gray-400',
      'syncing' => 'bg-blue-100 text-blue-900 border-blue-900',
      'ready' => 'bg-green-100 text-green-900 border-green-900',
      'failed' => 'bg-red-100 text-red-900 border-red-900'
    }.freeze

    STATUS_ICONS = {
      'never_synced' => 'dash-circle',
      'syncing' => 'arrow-repeat',
      'ready' => 'check-circle',
      'failed' => 'exclamation-triangle'
    }.freeze

    # An unknown status renders like never_synced instead of raising — the pill
    # only displays state, it must never take a page down.
    FALLBACK_STATUS = 'never_synced'

    def initialize(status:)
      super()
      @status = status.to_s
    end

    def call
      tag.span(class: "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium #{style}") do
        safe_join([tag.i('', class: "bi bi-#{icon}"), label])
      end
    end

    private

    def style
      STATUS_STYLES.fetch(@status, STATUS_STYLES.fetch(FALLBACK_STATUS))
    end

    def icon
      STATUS_ICONS.fetch(@status, STATUS_ICONS.fetch(FALLBACK_STATUS))
    end

    def label
      t("views.organisations.documentation.sync_status.#{@status}", default: @status.humanize)
    end
  end
end

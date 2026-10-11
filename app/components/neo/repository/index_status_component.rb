# frozen_string_literal: true

module Neo
  module Repository
    # Live status display for a repo's ProjectIndex: a status badge plus the
    # Layer-1 file progress (while indexing), the last-indexed time (when ready),
    # or the error message (when failed).
    #
    # Deliberately CONTEXT-FREE — it reads only the ProjectIndex and uses just
    # `t` and `time_ago_in_words`. No current_user, no Pundit, no model-specific
    # URL helpers — so ProjectIndex#broadcast_status can re-render it from a
    # background job (no request/session) on every status transition. The
    # write-gated webhook-setup block lives in the connect view, NOT here.
    class IndexStatusComponent < ViewComponent::Base
      # Neo-Brutalist badge palette per index status. Unknown statuses fall back
      # to the neutral style so a new enum value can never blow up the view.
      STATUS_STYLES = {
        'pending' => 'bg-gray-100 text-gray-700',
        'indexing' => 'bg-blue-100 text-blue-800',
        'ready' => 'bg-green-100 text-green-800',
        'failed' => 'bg-red-100 text-red-800',
        'stale' => 'bg-yellow-100 text-yellow-900'
      }.freeze
      DEFAULT_STYLE = 'bg-gray-100 text-gray-700'

      # Statuses during which the Layer-1 file counter is meaningful.
      IN_PROGRESS_STATUSES = %w[indexing stale].freeze

      def initialize(index:)
        @index = index
      end

      def status_style
        STATUS_STYLES.fetch(@index.status, DEFAULT_STYLE)
      end

      def status_label
        t("views.organisations.indexing.status.#{@index.status}", default: @index.status.to_s.humanize)
      end

      # Show the file counter only while work is happening AND a total is known
      # (total is 0 until the walker has counted the files).
      def show_progress?
        IN_PROGRESS_STATUSES.include?(@index.status) && @index.layer_1_files_total.to_i.positive?
      end

      def progress_text
        t('views.organisations.indexing.progress',
          done: @index.layer_1_files_done, total: @index.layer_1_files_total)
      end

      def ready?
        @index.status == 'ready'
      end

      def failed?
        @index.status == 'failed'
      end

      def last_indexed_text
        return t('views.organisations.indexing.never_indexed') if @index.last_indexed_at.blank?

        t('views.organisations.indexing.last_indexed', time: time_ago_in_words(@index.last_indexed_at))
      end
    end
  end
end

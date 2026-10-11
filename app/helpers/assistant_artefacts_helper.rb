# frozen_string_literal: true

# View side of the assistant's artefact lane (S3c T3, plan §8.1).
module AssistantArtefactsHelper
  # The four filters a time report is addressed by, frozen on the citation the
  # answer already carries (Lalabase::Citations.time_report).
  REPORT_FILTER_KEYS = %i[start_date end_date creator_id ticket_id].freeze

  # The time list, opened on exactly the set the report covers. ONE owner of this
  # address: the source chip under an answer (Neo::Chat::CitationListComponent)
  # and the way out of the report panel are the same link, and a report whose two
  # doors lead to two different lists is worse than one door.
  #
  # LIST_NEUTRAL_DRILLDOWN_PARAMS first: the time list defaults to the current
  # month with billed rows hidden, which would silently show something else than
  # the numbers above it.
  def assistant_report_list_path(organisation, project, filters)
    # A JSONB row can hold anything, so a non-Hash is a case that reaches here
    # (there is a spec for it): a malformed citation degrades to the neutralised
    # list, it does not take the whole answer down with it.
    applied = (filters.is_a?(Hash) ? filters.symbolize_keys : {}).slice(*REPORT_FILTER_KEYS).compact
    time_list_path(organisation, project: project, **TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS, **applied)
  end

  # What the numbers cover, in one line.
  #
  # ⚠️ It names NOBODY and NOTHING it was handed an id for. creator_id and
  # ticket_id arrive in a typeable address, so resolving them to a name would turn
  # the header into a lookup service for records this reader may not see -- the
  # rows themselves are filtered, but a headline is rendered before any row is.
  # The one exception is the reader's own id, which tells them nothing new.
  def assistant_report_filter_summary(panel)
    parts = [assistant_report_period(panel.filters)]
    parts << if panel.filters[:creator_id] == current_user&.id
               t('views.organisations.assistant_artefacts.report.filters.own_bookings')
             elsif panel.filters[:creator_id].present?
               t('views.organisations.assistant_artefacts.report.filters.one_person')
             end
    parts << t('views.organisations.assistant_artefacts.report.filters.one_ticket') if panel.filters[:ticket_id].present?
    parts.compact.join(' · ')
  end

  private

  # Full dates, never `format: :short`: that format carries no year, and a billing
  # period without one is ambiguous the moment January arrives.
  def assistant_report_period(filters)
    from = filters[:start_date].present? ? l(Date.parse(filters[:start_date])) : nil
    upto = filters[:end_date].present? ? l(Date.parse(filters[:end_date])) : nil
    scope = 'views.organisations.assistant_artefacts.report.filters'

    if from && upto
      t("#{scope}.period", from: from, to: upto)
    elsif from
      t("#{scope}.period_from", from: from)
    elsif upto
      t("#{scope}.period_until", to: upto)
    else
      t("#{scope}.all_time")
    end
  end
end

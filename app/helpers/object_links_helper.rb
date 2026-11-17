# frozen_string_literal: true

# The object chips of rich text (ObjectLinks::Chips) for the page being rendered: who the
# reader is, which organisation the page belongs to, which hosts are this instance.
#
# Without a reader (a job, a mail, the console, a broadcast: ObjectLinkRenderGuard), without
# the page's organisation as the tenant, and on any error the text renders as it was
# stored: a link is always a correct answer, a chip only an improvement on it.
module ObjectLinksHelper
  # The whole ActionText layout's content (layouts/action_text/contents/_content).
  def object_link_chips(html)
    context = object_link_context
    return html unless context

    ObjectLinks::Chips.apply(html: html, **context)
  rescue StandardError => e
    object_link_failure(e)
    html
  end

  # Loads the chip targets of many records' rich texts at once, before a list renders them
  # one by one (the ticket timeline). Only a speed-up: without it each text loads its own.
  def object_link_prefetch(records)
    context = object_link_context
    return unless context

    htmls = records.filter_map { |record| record.content&.body&.to_html if record.respond_to?(:content) }
    ObjectLinks::Chips.prefetch(htmls: htmls, **context)
    nil
  rescue StandardError => e
    object_link_failure(e)
    nil
  end

  private

  def object_link_context
    return if ObjectLinkRenderGuard.suppressed?

    viewer = viewer_user
    organisation = ActsAsTenant.current_tenant
    return unless viewer && organisation.is_a?(Organisation)

    { viewer: viewer, organisation: organisation, hosts: object_link_hosts }
  end

  # The host this page is served on, and the hosts the instance answers on
  # (Lalabase::InstanceSettings, config.hosts in production).
  def object_link_hosts
    [request&.host, *Lalabase::InstanceSettings.hosts].compact
  end

  # Loud where a developer looks, quiet for a reader: the link stays either way.
  def object_link_failure(error)
    raise error if Rails.env.local? && !ObjectLinksHelper.tolerate_errors

    Rails.error.report(error, handled: true, source: 'object_links')
  end

  class << self
    # A spec sets it to hold the fallback; development and test re-raise otherwise.
    attr_accessor :tolerate_errors
  end
end

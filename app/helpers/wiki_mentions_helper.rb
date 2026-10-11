# frozen_string_literal: true

# Path for a mentioned wiki record (note or document). Centralised so the rendered
# mention chip and (later) any other consumer agree on where a mention points.
module WikiMentionsHelper
  def wiki_mention_path(record)
    case record
    when Note
      organisation_project_note_path(record.organisation, record.project, record)
    when Document
      organisation_project_document_path(record.organisation, record.project, record)
    end
  end

  # May the current viewer actually open this mention target? Mentions are project-local,
  # but note→document crosses areas — so a viewer with notes-read but not documents-read
  # could otherwise see a document's title + a working backlink via a rendered chip. The
  # chip uses this to render an inert label instead of a link in that case. Fails safe
  # (no link) when there is no user context (e.g. a background/console render).
  def wiki_mention_readable?(record)
    user = current_user if respond_to?(:current_user)
    return false unless user && record

    Pundit.policy(user, record)&.show? || false
  rescue Pundit::NotDefinedError
    false
  end
end

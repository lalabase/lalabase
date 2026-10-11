# frozen_string_literal: true

module AttachmentsHelper
  # Paths to the authorized file proxy for post-/ticket-document attachments. Centralises the
  # `kind` key + URL construction (mirrors DocumentsHelper#document_version_download_path) so
  # views never link the unprotected default blob route for these project-scoped files. Each
  # kind must be registered in FileDownloadsController::DOWNLOADABLES.
  def post_document_download_path(post_document)
    organisation_file_download_path(
      organisation_id: post_document.post.ticket.project.organisation_id,
      kind: 'post_document',
      id: post_document.id
    )
  end

  def ticket_document_download_path(ticket_document)
    organisation_file_download_path(
      organisation_id: ticket_document.ticket.project.organisation_id,
      kind: 'ticket_document',
      id: ticket_document.id
    )
  end

  # Dispatches to the right proxy path for the shared attachment partial, which handles both
  # PostDocument and TicketDocument.
  def attachment_download_path(document)
    case document
    when PostDocument then post_document_download_path(document)
    when TicketDocument then ticket_document_download_path(document)
    end
  end

  # The file's KIND by content type, ONE table for the icon and the word: the
  # file chip signals the kind (a PDF as a PDF, not just "a link"), and the
  # document's attribute row names it (S3 of doc/dokumentansicht_plan.md).
  # First match wins, so the order is the icon's old case order; :text is new
  # and used to fall through to the generic file.
  FILE_KINDS = [
    [%r{\Aapplication/pdf\z}, :pdf],
    [%r{\Aimage/}, :image],
    [/word|opendocument\.text/, :word],
    [/sheet|excel|csv/, :sheet],
    [/zip|compressed|x-tar|x-7z/, :archive],
    [%r{\Atext/plain\z}, :text]
  ].freeze
  FILE_KIND_ICONS = {
    pdf: 'bi-file-earmark-pdf', image: 'bi-file-earmark-image', word: 'bi-file-earmark-word',
    sheet: 'bi-file-earmark-spreadsheet', archive: 'bi-file-earmark-zip', text: 'bi-file-earmark-text',
    file: 'bi-file-earmark'
  }.freeze

  # :pdf, :image, :word, :sheet, :archive, :text, or :file for everything else.
  def attachment_file_kind(file)
    type = file.content_type.to_s
    FILE_KINDS.find { |pattern, _kind| type.match?(pattern) }&.last || :file
  end

  # Bootstrap-Icon name for a non-previewable attachment, by kind.
  def attachment_file_icon(file)
    FILE_KIND_ICONS.fetch(attachment_file_kind(file))
  end

  # "PDF", "Bild", "Tabelle": the kind as a word (views.shared.file_kinds).
  def attachment_file_kind_word(file)
    t("views.shared.file_kinds.#{attachment_file_kind(file)}")
  end
end

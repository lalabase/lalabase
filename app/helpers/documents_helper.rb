# frozen_string_literal: true

module DocumentsHelper
  # Path to the authorized file proxy for a DocumentVersion.
  #
  # Centralizes the `kind` key ('document_version') and the URL construction in
  # ONE place — otherwise the view and the controller each maintain their own copy including the
  # magic string. If the proxy routing or the kind changes, only this needs to be touched.
  # The kind must be registered in FileDownloadsController::DOWNLOADABLES.
  def document_version_download_path(version)
    organisation_file_download_path(
      organisation_id: version.document.project.organisation_id,
      kind: 'document_version',
      id: version.id
    )
  end

  # The browser images the preview shows as an <img> (D3 of
  # doc/dateivorschau_plan.md): an explicit list, every one of them a type the
  # proxy serves inline. SVG is an image the proxy forces to download, TIFF, BMP
  # and PSD ones the browser cannot show; they fall to the fourth case. A rule
  # for the display, not an upload restriction.
  PREVIEW_IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp image/avif].freeze

  # The case the preview renders for a version (D3): :image, :pdf, :text (a
  # text version is there), :text_missing (an extractable type whose text is
  # not there, or not yet), :none.
  def document_preview_kind(version)
    file = version.document_version_file
    return :none unless file.attached?

    type = file.content_type.to_s
    return :image if PREVIEW_IMAGE_TYPES.include?(type)
    return :pdf if type == 'application/pdf'
    return :text if version.plain_text_version.present?
    return :text_missing if ExtractPlainTextProcessingService.text_extractable?(type)

    :none
  end

  # A quiet text action beside a button (S2/S4 of doc/dokumentansicht_plan.md:
  # "als aktuell setzen" in the version row, "Abbrechen" under the forms). Ink,
  # not lime: lime text is not readable on cream. ONE owner, three callers.
  def text_action_classes
    'inline-flex h-8 items-center rounded-md px-2 text-[13px] text-cream-700 transition-colors ' \
      'hover:bg-cream-200 hover:text-cream-900 focus-visible:bg-cream-200 focus-visible:text-cream-900'
  end
end

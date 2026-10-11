# frozen_string_literal: true

module DocumentationHelper
  # Human message for a sync run's error_class (DT4 taxonomy). One place for
  # the unknown-class fallback: an error_class added to the job before its
  # locale key exists degrades to the generic message instead of raising.
  def documentation_sync_error_message(error_class)
    t("views.organisations.documentation.sync_error.#{error_class}",
      default: t('views.organisations.documentation.sync_error.generic'))
  end

  # The single line of a search result: the page title, falling back to the file
  # name when the source .md had no leading heading.
  def documentation_result_title(page)
    page.title.presence || File.basename(page.path)
  end
end

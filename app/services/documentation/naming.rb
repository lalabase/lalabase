# frozen_string_literal: true

module Documentation
  # Single place for the "repo file/folder name → human label" rule
  # ("getting-started" → "Getting Started"). Used by the sync job (page-title
  # fallback when a page has no H1) and the navigation tree (folder labels +
  # defensive page-label fallback) — change the rule here and every derived
  # label changes with it.
  module Naming
    module_function

    def humanize(name)
      name.to_s.tr('-_', '  ').strip.titleize
    end
  end
end

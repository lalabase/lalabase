# frozen_string_literal: true

# Which panel kinds the assistant's artefact lane knows, and what renders them
# (plan §8.1, S3c T3).
#
# Entry point: panel_for
module Assistant
  # Fail-closed by construction, after the pattern of
  # ProjectRag::ContentAreaRegistry: an unknown kind resolves to nil and the lane
  # answers with its refusal, rather than falling through to some default view.
  # The kind travels in a client-settable address, so "unknown" is a case that
  # arrives in production, not a typo that only a developer can cause.
  #
  # The list is open: a new kind is an entry here plus a partial of the same name
  # under app/views/organisations/assistant_artefacts/, no rebuild. `record` and
  # `results` join in S3b, `proposal` in S4b.
  class PanelRegistry
    PANELS = {
      'report' => Assistant::Panels::TimeReport
    }.freeze

    def self.panel_for(kind)
      PANELS[kind.to_s]
    end

    # The canonical kind, i.e. the key as this file spells it, or nil.
    #
    # It exists so the lane can render a template named after the kind WITHOUT
    # ever handing a request parameter to `render`. The check and the value then
    # come from the same place; taking the value from params after checking it
    # separately would work today and read as an invitation tomorrow.
    def self.canonical_kind(kind)
      PANELS.keys.find { |known| known == kind.to_s }
    end

    def self.kinds
      PANELS.keys
    end
  end
end

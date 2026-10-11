# frozen_string_literal: true

# Entry point: .for / #gone?
module Lalabase
  # Answers ONE question about a chat answer's citations: does the object behind
  # this citation still exist? (Feinschliff B, doc/assistent_oberflaeche_feinschliff_plan.md P5.)
  #
  # A citation freezes the display fields AND the ids at retrieval time, which is
  # what lets the source list render without a DB hit. That is right for the label
  # and wrong for the LINK: a ticket deleted after the answer was written still got
  # a link, and the click ended on an error page — in production not even a designed
  # one, because public/ is gitignored and the 404 page is missing there.
  #
  # Resolved EAGERLY and in bulk: one query per target type for a whole transcript,
  # never one per citation. ChatContainerComponent builds one of these for the list
  # (like the area_access cache next to it) and hands it down; the streaming
  # broadcast, which renders a single bubble, builds its own.
  #
  # ⚠️ "gone" is a CLAIM and is only made on evidence. Without an organisation
  # there is no query and therefore no claim, and a citation this instance was
  # never asked to resolve is never called gone either. A wiring mistake thus
  # degrades to the old behaviour (a link that may 404), never to "every source of
  # this answer is deleted", which would be the same screen as a leak.
  class CitationTargets
    # Target type (Lalabase::Citations.target_of) → model. Names, not classes: a
    # constant holding a model class survives the dev reloader while the class it
    # points at does not.
    #
    # Deliberately without help_page: a help page belongs to no organisation, so it is never
    # asked for and never called gone. A page a later release removes keeps its link, and
    # /hilfe answers that with its own designed not-found page (HelpController#show).
    MODEL_NAMES = {
      'ticket' => 'Ticket',
      'note' => 'Note',
      'document' => 'Document',
      'documentation' => 'DocumentationPage',
      'meeting' => 'Meeting',
      'project' => 'Project'
    }.freeze

    EMPTY = Set.new.freeze

    def self.for(citations:, organisation:)
      new(citations: citations, organisation: organisation)
    end

    def initialize(citations:, organisation:)
      @organisation = organisation
      @asked = {}
      @present = {}
      resolve(citations)
    end

    # True only when this instance QUERIED for the citation's target and the target
    # was not there. Everything else is false: the code layer (no target at all), an
    # unknown target type, a missing organisation, and any citation outside the list
    # this instance was built from.
    def gone?(citation)
      target = Lalabase::Citations.target_of(citation)
      return false if target.nil?
      return false unless @asked.fetch(target[:type], EMPTY).include?(target[:id])

      !@present.fetch(target[:type], EMPTY).include?(target[:id])
    end

    private

    def resolve(citations)
      return if @organisation.nil?

      ids_by_type(citations).each do |type, ids|
        @asked[type] = ids
        @present[type] = existing_ids(type, ids)
      end
    end

    # The distinct target ids per type, ignoring citations without a target.
    def ids_by_type(citations)
      list = citations.is_a?(Array) ? citations : []
      list.each_with_object({}) do |citation, acc|
        target = Lalabase::Citations.target_of(citation)
        next if target.nil? || !MODEL_NAMES.key?(target[:type])

        (acc[target[:type]] ||= Set.new) << target[:id]
      end
    end

    # organisation_id in the WHERE on top of with_tenant: the scope must hold even
    # in the streaming broadcast, where the ambient tenant belongs to whoever
    # happened to run last (require_tenant = true would otherwise raise there).
    #
    # ⚠️ An id that is not a UUID casts to NULL and matches nothing, so a malformed
    # citation reads as gone. That is the honest answer — it points at no record —
    # and it is why `asked` is tracked separately: only ids we actually looked for
    # can be called gone.
    def existing_ids(type, ids)
      model = MODEL_NAMES.fetch(type).constantize
      ActsAsTenant.with_tenant(@organisation) do
        model.where(organisation_id: @organisation.id, id: ids.to_a).pluck(:id).to_set
      end
    end
  end
end

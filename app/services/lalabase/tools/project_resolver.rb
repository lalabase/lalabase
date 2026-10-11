# frozen_string_literal: true

module Lalabase
  module Tools
    # Resolves the `project` filter of an org-wide tool call (S3a T5, plan §9.3).
    # Entry point: call
    #
    # WHY this exists: the org-capable tools reach every project the asker may
    # read, and a question like "how many tickets does Nordlicht have?" had no way
    # to say so. The model would have to count rows off one paginated page, which
    # is wrong the moment there is a second page. A filter answers it exactly.
    #
    # It NARROWS and never widens: candidates are handed in by the calling tool,
    # drawn from the reach that tool actually has, so the asker's rights and the
    # scope chip both still apply. A project outside them is simply not found.
    #
    # Users say "Nordlicht", not a UUID, and names are neither unique nor exact.
    # An ambiguous or unknown name therefore answers with CANDIDATES rather than
    # an error or a silent zero -- the same §9.2 shape TicketCandidates uses for
    # ambiguous ticket numbers, for the same reason: the model turns a candidate
    # list into a follow-up question the user answers with one click, while a
    # silent zero is indistinguishable from a real answer.
    module ProjectResolver
      DEFAULT_LIMIT = 10

      # @param reachable [ActiveRecord::Relation, Array<Project>] the projects
      #   this call may touch. Handed IN rather than derived here: not every
      #   org-capable tool draws its reach from the per-area gate. Time sessions
      #   have no `time_sessions` area on ProjectPermission at all -- their
      #   all/own/none rule lives in TimeSessions::ViewingScope (§2.4) -- so a
      #   resolver that asked the area gate itself would raise there.
      # @return [Project, Hash] the one project meant, or a payload the tool
      #   should return INSTEAD of rows.
      def self.call(value, reachable:, limit: DEFAULT_LIMIT)
        reachable = reachable.order(:name) if reachable.respond_to?(:order)
        matches = match(reachable, value.to_s.strip)

        return matches.first if matches.size == 1

        payload(value, matches.presence || reachable, ambiguous: matches.size > 1, limit: limit)
      end

      # The list a call answers with when it NEEDS a project and the question named
      # none (assistant code tools, doc/assistent_code_werkzeuge_plan.md §A rung 5).
      # Separate from #call on purpose: nothing was requested, so neither
      # `ambiguous_project` nor `unknown_project` is true, and a model handed
      # either word asks the wrong follow-up question. It lives HERE because the
      # shape of "answer with candidates instead of guessing" has one owner.
      def self.candidates_payload(reachable, limit: DEFAULT_LIMIT)
        reachable = reachable.order(:name) if reachable.respond_to?(:order)
        list = reachable.to_a
        {
          project_required: true,
          candidates_total: list.size,
          candidates: list.first(limit).map { |p| { id: p.id, name: p.name } }
        }
      end

      # Exact name first, then a contained match. Without the two-step an
      # organisation running "Portal" and "Portal v2" could never address the
      # first one: it is contained in the second, so the call would be
      # permanently ambiguous.
      def self.match(reachable, value)
        return [] if value.blank?

        by_id = reachable.select { |p| p.id == value }
        return by_id if by_id.any?

        exact = reachable.select { |p| p.name.casecmp?(value) }
        return exact if exact.any?

        reachable.select { |p| p.name.downcase.include?(value.downcase) }
      end
      private_class_method :match

      def self.payload(value, candidates, ambiguous:, limit:)
        {
          # Two different situations, said apart: "which of these did you mean"
          # versus "I cannot see a project by that name". A model that gets one
          # word for both asks the wrong follow-up question.
          ambiguous_project: ambiguous,
          unknown_project: !ambiguous,
          requested: value,
          candidates_total: candidates.size,
          candidates: candidates.first(limit).map { |p| { id: p.id, name: p.name } }
        }
      end
      private_class_method :payload
    end
  end
end

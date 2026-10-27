# frozen_string_literal: true

# The lines of the link dialog for one meeting participant (S2b, E6), read from
# the viewer's own directory (People::Directory), so nobody the viewer may not
# see is listed:
# * without a search, the suggestions first (same full name, then same
#   surname), marked as such;
# * then everyone the search finds, at most `limit` of them;
# * a pick that came back with a refusal (choice) is drawn again checked. It
#   must be in the list for that, and in it once: wherever the search found it,
#   or ahead of the others when it lies past the limit.
#
# Entry point: lines
module Meetings
  class ParticipantLinkOptions
    Line = Data.define(:entry, :suggested) do
      def suggested? = suggested
    end

    def initialize(viewer:, organisation:, participant:, query:, limit:, choice: nil)
      @directory = People::Directory.new(viewer: viewer, organisation: organisation, query: query)
      @participant = participant
      @query = query
      @limit = limit
      @choice = choice
    end

    def lines
      suggested = @query.blank? ? @directory.suggestions_for(@participant.display_name) : []
      others = (@directory.candidates - suggested).first(@limit)

      picked = picked_entry
      already_listed = suggested.include?(picked) || others.include?(picked)
      others.unshift(picked) if picked && !already_listed

      suggested.map { |entry| Line.new(entry: entry, suggested: true) } +
        others.map { |entry| Line.new(entry: entry, suggested: false) }
    end

    private

    # The entry the refused pick names, through the same directory, or nil.
    def picked_entry
      choice = ParticipantLinkChoice.parse(@choice)
      case choice&.kind
      when :person then @directory.person_entry(choice.id)
      when :member then @directory.member_entry(choice.id)
      end
    end
  end
end

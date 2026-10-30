# frozen_string_literal: true

module Lalabase
  module Tools
    # The title of a ticket as a token write takes it: create_ticket checks it
    # here, and Tickets::Change for update_ticket and the HTTP API, so the
    # surfaces cannot drift apart. ONE line of printable text, at most
    # Ticket::TITLE_MAX_LENGTH characters (the model holds the bound, this answers
    # it first, as a refusal of the input).
    #
    # Refused, not cleaned: web titles are not normalised, and silently changing
    # what a client sent would make the answer differ from the input. The check
    # runs on the value as sent, before the edges are trimmed, so a control
    # character at the start or the end is refused instead of cut away unseen.
    #
    # Entry point: read (the refusal named, for Tickets::Change, which leaves the
    # wording to its callers) or check (the refusal in the English of the tools)
    module TicketTitle
      # The name contract's invisible and direction characters
      # (Project::NAME_INVISIBLE_CHARS), plus what that set leaves to its
      # normaliser or does not name: line breaks and tabs, the Arabic letter mark,
      # the Mongolian vowel separator and the interlinear annotation characters.
      FORBIDDEN = Regexp.union(Project::NAME_INVISIBLE_CHARS,
                               /[\t\n\v\f\r\u0085\u2028\u2029\u061C\u180E\uFFF9-\uFFFB]/)
      # Tag characters are invisible text (and a title reaches the assistant's
      # prompt). They are kept only inside the three subdivision flags Unicode
      # recommends and fonts draw (England, Scotland, Wales): the syntax allows
      # any region code, and a made-up one is hidden text all the same.
      TAG_CHARS = /[\u{E0000}-\u{E007F}]/
      FLAG = /\u{1F3F4}\u{E0067}\u{E0062}(?:\u{E0065}\u{E006E}\u{E0067}|\u{E0073}\u{E0063}\u{E0074}|\u{E0077}\u{E006C}\u{E0073})\u{E007F}/
      # Every kind of space, String#strip knows only ASCII.
      EDGE_SPACES = /\A[[:space:]]+|[[:space:]]+\z/
      # At least one character that shows: a letter, digit, punctuation or
      # symbol, minus the ones Unicode files as such but that draw nothing (the
      # Hangul fillers, the blank Braille pattern). Joiners, the soft hyphen and
      # variation selectors are no letters at all.
      VISIBLE = /[[\p{L}\p{N}\p{P}\p{S}]&&[^\u115F\u1160\u3164\uFFA0\u2800]]/

      # The refusals of the rule, in the order it checks, in the tools' wording.
      REFUSAL_TEXT = {
        title_not_string: 'title must be a string',
        title_invalid_utf8: 'title must be valid UTF-8',
        title_forbidden: 'title must be one line without control characters',
        title_empty: 'title is required',
        title_too_long: "title is longer than #{Ticket::TITLE_MAX_LENGTH} characters"
      }.freeze
      REFUSALS = REFUSAL_TEXT.keys.freeze

      # @return [String] the title to store, or [Result] the refusal to return
      def self.check(value)
        title = read(value)
        title.is_a?(Symbol) ? Result.invalid_input(REFUSAL_TEXT.fetch(title)) : title
      end

      # @return [String] the title to store, or [Symbol] the refusal (REFUSALS)
      def self.read(value)
        return :title_not_string unless value.is_a?(String)
        return :title_invalid_utf8 unless value.valid_encoding?
        return :title_forbidden if forbidden?(value)

        title = value.gsub(EDGE_SPACES, '')
        return :title_empty unless title.match?(VISIBLE)
        return :title_too_long if title.length > Ticket::TITLE_MAX_LENGTH

        title
      end

      def self.forbidden?(value)
        value.match?(FORBIDDEN) || value.gsub(FLAG, '').match?(TAG_CHARS)
      end
      private_class_method :forbidden?
    end
  end
end

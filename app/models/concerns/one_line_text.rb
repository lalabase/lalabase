# frozen_string_literal: true

# One-line form of a free-text attribute, for surfaces that need a bounded
# single line: the assistant's system prompt writes it into a sentence, a
# reference chip has 380px of panel. The NUMBER belongs to the caller and the
# FORM lives here, once: whitespace collapsed BEFORE the cut, so a pasted
# multi-line value does not spend its whole budget on newlines and break the
# one-line shape the callers need. Owners: Ticket#one_line_title,
# Project#one_line_name.
module OneLineText
  private

  def one_line(text, max:)
    text.to_s.gsub(/\s+/, ' ').strip.truncate(max)
  end
end

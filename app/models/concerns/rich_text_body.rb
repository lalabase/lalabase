# frozen_string_literal: true

# The plain text mirror of a rich text body: before every save the carrier's
# `content` is written as plain text into plain_text_version and its words are
# counted into plain_text_word_count. Lists, excerpts and counters read the two
# columns instead of parsing the rich text.
#
# The one owner of this code. A carrier declares `has_rich_text :content` and
# `include RichTextEmbedGuard` itself and then includes this concern: the guard
# of the embed rule reads every file under app/models for both lines
# (spec/models/action_text/rich_text_embed_guard_inclusion_spec.rb), so
# has_rich_text cannot move in here.
#
# Where the include stands decides where the callback runs among the
# carrier's other before_save callbacks. Post and Note include it where their
# own before_save line stood, so their chains are what they were. (Note
# derives its markdown body right after it; the two do not read each other.)
#
# The method keeps its name: the N+1 watch of the specs allows the queries of
# extract_plain_text_content by that name (spec/support/prosopite.rb).
# Held for every carrier by spec/models/concerns/rich_text_body_spec.rb.
module RichTextBody
  extend ActiveSupport::Concern

  included do
    before_save :extract_plain_text_content
  end

  private

  def extract_plain_text_content
    self.plain_text_version = content&.to_plain_text
    self.plain_text_word_count = count_words(content&.to_plain_text)
  end

  def count_words(text)
    text.split(/\s+/).reject(&:blank?).size
  end
end

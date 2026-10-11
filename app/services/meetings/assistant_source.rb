# frozen_string_literal: true

# Shared bounded meeting source text for explicit assistant reads.
module Meetings
  # Shared source preparation for explicit assistant meeting reads and task runs.
  class AssistantSource
    MAX_TEXT_CHARS = 8_000

    def self.call(raw:)
      text = Meeting.strip_frontmatter(raw).to_s
      {
        text_format: 'markdown', text_status: text.present? ? 'available' : 'empty',
        text_length: text.length, text_truncated: text.length > MAX_TEXT_CHARS,
        text: text.length > MAX_TEXT_CHARS ? "#{text[0, MAX_TEXT_CHARS]}\n\n…[truncated]" : text
      }
    end

    def self.metadata(source:)
      source.except(:text).merge(sha256: Digest::SHA256.hexdigest(source.fetch(:text)))
    end
  end
end

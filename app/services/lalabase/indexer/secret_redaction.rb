# frozen_string_literal: true

module Lalabase
  module Indexer
    # Strips a repo access token out of error messages, log lines and re-raised
    # exceptions so it never lands in long-lived storage (SolidQueue failures,
    # error trackers). Shared by ProjectIndexerJob and RepoReindexJob.
    module SecretRedaction
      module_function

      def redact(message, token)
        return message if token.blank?

        message.to_s.gsub(token, '[REDACTED]')
      end

      # Re-raise-safe: returns a new exception of the same class with a redacted
      # message + backtrace. Downstream (SolidQueue::FailedExecution, error
      # trackers) capture #message and #backtrace verbatim — if the token appears
      # there it lands in storage outside our control. Preserves the original
      # class for retry_on/discard_on semantics. Falls back to StandardError when
      # the class can't be rebuilt from a single string arg — e.g. AR exceptions
      # that want a record (ArgumentError) or one that type-checks its arg
      # (TypeError). We must not let the redaction path itself raise.
      def scrub_exception(original, token)
        return original if token.blank?

        sanitized_msg = redact(original.message, token)
        scrubbed = begin
          original.class.new(sanitized_msg)
        rescue ArgumentError, TypeError
          StandardError.new(redact("#{original.class}: #{original.message}", token))
        end
        scrubbed.set_backtrace((original.backtrace || []).map { |l| redact(l, token) })
        scrubbed
      end
    end
  end
end

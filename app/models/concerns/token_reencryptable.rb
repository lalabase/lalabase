# frozen_string_literal: true

# Shared maintenance entry point for every model owning encrypted token columns:
# rewrites each declared column through its encrypted attribute type so the row
# ends up under the CURRENT primary key — cleartext backfill and key rotation in
# one mechanism (previous READ scheme: see the encryption initializer). Third
# copy of this logic triggered the unification (was: Admin::AiCredential and
# ProjectRepository hand-rolled twins).
#
# Contract per model: `include TokenReencryptable` + `reencrypts_tokens :col, ...`.
# Exactly ONE model per TABLE registers (shadow models share tables); the guard
# spec spec/models/token_reencryptable_guard_spec.rb enforces that every
# `encrypts` column app-wide is covered by exactly one registration — so a new
# encrypted column cannot be forgotten by rake encryption:reencrypt_tokens.
#
# Row semantics (pinned in the model specs):
# * update_columns — no validations/callbacks (legacy rows may predate today's
#   rules), updated_at untouched (repair, not a domain change). Idempotent: an
#   already-current row is re-wrapped with a fresh IV.
# * An undecryptable value is logged and skipped, never rewritten. Since the
#   support_unencrypted_data cutoff it RAISES on read anyway; the additional
#   encrypted?-check on the read value stays as defense-in-depth — with the
#   bridge flag on, a failed decryption surfaces as the raw envelope instead of
#   an error, and rewriting that would double-wrap it under the new key while
#   reporting success ("falsches Grün").
# * Per-COLUMN isolation: a broken column never blocks the healthy sister
#   column of the same row (it would otherwise stay under the old key and die
#   with it), and a broken row never aborts the batch.
# * Returns { processed:, failed: } — failures must surface in the task
#   summary and its exit code, not only in a log line, because the follow-up
#   operational step (removing the previous READ scheme) is irreversible.
# * without_tenant: ops/maintenance entry point (rake encryption:reencrypt_tokens),
#   never a user-facing query path.
module TokenReencryptable
  extend ActiveSupport::Concern

  # Class name (string, reload-safe) => frozen column list. Populated by the
  # `reencrypts_tokens` declarations; consumed by the rake task and the guard.
  def self.registry
    @registry ||= {}
  end

  class_methods do
    def reencrypts_tokens(*columns)
      TokenReencryptable.registry[name] = columns.freeze
    end

    def reencrypt_tokens!
      columns = TokenReencryptable.registry.fetch(name)
      processed = 0
      failed = 0
      ActsAsTenant.without_tenant do
        find_each do |record|
          updates = {}
          skipped = []
          columns.each do |column|
            updates[column] = readable_token_value!(record, column)
          rescue StandardError => e
            skipped << column
            Rails.logger.warn("[reencrypt_tokens] skipped #{table_name}.#{column} for #{record.id}: #{e.class}: #{e.message}")
          end
          # A row whose readable columns are ALL blank has nothing to rewrite:
          # no UPDATE, no counter. "processed" counts FULLY rewritten rows —
          # a row with a skipped sister column gets its healthy columns
          # rewritten but counts only as failed, so the operator's numbers
          # stay conservative for the irreversible rotation step.
          rewritable = updates.values.any?(&:present?)
          record.update_columns(updates) if rewritable
          if skipped.any?
            failed += 1
          elsif rewritable
            processed += 1
          end
        rescue StandardError => e
          failed += 1
          Rails.logger.warn("[reencrypt_tokens] skipped #{table_name} #{record.id}: #{e.class}: #{e.message}")
        end
      end
      Rails.logger.warn("[reencrypt_tokens] #{failed} #{table_name} row(s) with skipped values") if failed.positive?
      { processed: processed, failed: failed }
    end

    private

    # The decrypted read of a healthy row is NEVER itself an encryption
    # envelope. If it is, decryption failed and the (currently disabled)
    # support_unencrypted_data bridge handed the raw ciphertext back — never
    # rewrite that. With the bridge off this check is defense-in-depth behind
    # the reader's own raise; it stays because the flag is one config line away
    # and this method must not depend on it. Message deliberately names only
    # the column, never the value.
    def readable_token_value!(record, column)
      value = record.public_send(column)
      if value.present? && ActiveRecord::Encryption.encryptor.encrypted?(value)
        raise ActiveRecord::Encryption::Errors::Decryption,
              "#{column} read back as ciphertext — row not decryptable under the configured keys"
      end
      value
    end
  end
end

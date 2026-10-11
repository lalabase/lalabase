# frozen_string_literal: true

# KI-Pakete P0 (doc/ki_pakete_plan.md §7b.2): pin the system credential a held
# embedding space runs on. Until now Factory.system_credentials resolved by
# provider NAME (active_for_provider) — unambiguous only while the partial
# unique index allows a single active credential per provider. With packages,
# two openai_compatible system credentials (Mistral FR / IONOS DE) coexist,
# and a Mistral space would silently receive the IONOS key — wrong endpoint
# secret plus mis-attributed metering (§9 Falle 4).
#
# NULL keeps the legacy meaning "resolve the provider's default credential".
# Existing rows are deliberately NOT backfilled: they were created under the
# one-active-per-provider regime, where the default IS what served them;
# pinning them now would freeze today's default assignment — semantics those
# rows never had. New/refreshed rows get the id via Embeddings::EnsureSpace.
#
# on_delete: :nullify matches the snapshot nature of this table: deleting the
# credential degrades the row back to name-based resolution instead of
# blocking the delete. (The future package FKs use restrict — a package
# ADVERTISES a credential, a space merely REMEMBERS one; plan §7b.2.)
class AddAiCredentialToEmbeddingSpaces < ActiveRecord::Migration[8.0]
  def change
    add_reference :embedding_spaces, :ai_credential, type: :uuid, null: true,
                                                     foreign_key: { on_delete: :nullify }, index: true
  end
end

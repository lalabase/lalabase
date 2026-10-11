# frozen_string_literal: true

namespace :encryption do
  # Rewrites every encrypted-at-rest token column through its attribute type so
  # all rows end up under the CURRENT primary key — one pass covering both the
  # cleartext backfill and key rotation. Iterates the TokenReencryptable
  # registry (one owner model per table; completeness enforced by
  # spec/models/token_reencryptable_guard_spec.rb, semantics + specs live in
  # the concern). Idempotent. Operational order (keys first, previous scheme
  # during rotation): see the ops guide referenced in
  # config/initializers/active_record_encryption.rb.
  desc 'Alle verschluesselten Tokens unter dem aktuellen Schluessel neu schreiben (Backfill + Rotation)'
  task reencrypt_tokens: :environment do
    Rails.application.eager_load! # populate the registry in lazy-loading envs

    # An empty registry must never read as success: this task's summary gates
    # the irreversible removal of the previous READ scheme, and an empty sweep
    # that prints nothing and exits 0 would green-light it vacuously.
    if TokenReencryptable.registry.empty?
      abort 'encryption:reencrypt_tokens — Registry ist LEER, kein Modell registriert: es wurde NICHTS ' \
            'umgeschrieben. Eager-Loading/Registrierungen pruefen; NICHT mit der Schluessel-Rotation fortfahren.'
    end

    failed_total = 0
    lines = TokenReencryptable.registry.keys.sort.map do |class_name|
      klass = class_name.constantize
      # Total row count next to the counters: "0 von 0" (empty table) must be
      # distinguishable from "0 von 4" (nothing swept) in the operator's log.
      total = ActsAsTenant.without_tenant { klass.count }
      result = klass.reencrypt_tokens!
      failed_total += result[:failed]
      "#{klass.table_name}: #{result[:processed]} von #{total} neu verschluesselt, #{result[:failed]} uebersprungen"
    end
    puts "encryption:reencrypt_tokens — #{lines.join(' | ')}"
    if failed_total.positive?
      # A skipped value was NOT readable under the configured keys and was left
      # untouched. Removing the previous READ scheme now would make it
      # permanently unreadable — fail loudly (non-zero exit), never quietly.
      # Deliberate duplication: the deprecated ai_credentials:reencrypt_access_tokens
      # task carries the same gate message (marked there too) — change both together.
      abort "encryption:reencrypt_tokens — #{failed_total} Zeile(n) uebersprungen (Details im Log). " \
            'NICHT mit der Schluessel-Rotation fortfahren, bevor das geklaert ist.'
    end
  end
end
